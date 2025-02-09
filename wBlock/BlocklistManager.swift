//
//  BlocklistManager.swift
//  wBlock Origin
//
//  Created by Alexander Skula on 7/17/24.
//

import Foundation
import Combine
import SafariServices
import ContentBlockerConverter

enum FilterListCategory: String, CaseIterable, Identifiable {
    case all = "All", ads = "Ads", privacy = "Privacy", security = "Security", multipurpose = "Multipurpose", annoyances = "Annoyances", experimental = "Experimental"
    var id: String { self.rawValue }
}

struct FilterList: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let url: URL
    let category: FilterListCategory
    var isSelected: Bool = false
}

@MainActor
class FilterListManager: ObservableObject {
    @Published var filterLists: [FilterList] = []
    @Published var isUpdating = false
    @Published var progress: Float = 0
    @Published var missingFilters: [FilterList] = []
    @Published var logs: String = ""
    @Published var showProgressView = false
    @Published var availableUpdates: [FilterList] = []
    @Published var showingUpdatePopup = false
    @Published var hasUnappliedChanges = false
    @Published var showMissingFiltersSheet = false
    @Published var showRecommendedFiltersAlert = false
    
    private let contentBlockerIdentifier = "app.netlify.0xcube.wBlock.wBlockFilters"
    private let sharedContainerIdentifier = "group.app.netlify.0xcube.wBlock"
    
    init() {
        checkAndCreateGroupFolder()
        loadFilterLists()
        loadSelectedState()
        checkAndCreateBlockerList()
        checkAndEnableFilters()
        clearLogs()
    }
    
    func loadFilterLists() {
        filterLists = [
            FilterList(name: "AdGuard Base filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/2_optimized.txt")!, category: .ads, isSelected: true),
            FilterList(name: "AdGuard Tracking Protection filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/4_optimized.txt")!, category: .privacy, isSelected: true),
            FilterList(name: "AdGuard Annoyances filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/14_optimized.txt")!, category: .annoyances),
            FilterList(name: "AdGuard Social Media filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/3_optimized.txt")!, category: .annoyances),
            FilterList(name: "Fanboy's Annoyances filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/122_optimized.txt")!, category: .annoyances),
            FilterList(name: "EasyPrivacy", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/118_optimized.txt")!, category: .privacy, isSelected: true),
            FilterList(name: "Online Malicious URL Blocklist", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/208_optimized.txt")!, category: .security, isSelected: true),
            FilterList(name: "Peter Lowe's Blocklist", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/204_optimized.txt")!, category: .multipurpose, isSelected: true),
            FilterList(name: "Hagezi Pro mini", url: URL(string: "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/adblock/pro.mini.txt")!, category: .multipurpose, isSelected: true),
            FilterList(name: "d3Host List by d3ward", url: URL(string: "https://raw.githubusercontent.com/d3ward/toolz/master/src/d3host.adblock")!, category: .multipurpose, isSelected: true),
            FilterList(name: "Anti-Adblock List", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/207_optimized.txt")!, category: .multipurpose, isSelected: true),
            FilterList(name: "AdGuard Experimental filter", url: URL(string: "https://raw.githubusercontent.com/AdguardTeam/FiltersRegistry/master/platforms/extension/safari/filters/5_optimized.txt")!, category: .experimental),
        ]
    }
    
    private func loadSelectedState() {
        let defaults = UserDefaults.standard
        for (index, filter) in filterLists.enumerated() {
            filterLists[index].isSelected = defaults.bool(forKey: "filter_\(filter.name)")
        }
    }
    
    private func saveSelectedState() {
        let defaults = UserDefaults.standard
        for filter in filterLists {
            defaults.set(filter.isSelected, forKey: "filter_\(filter.name)")
        }
    }
    
    func checkAndEnableFilters() {
        missingFilters.removeAll()
        for filter in filterLists where filter.isSelected {
            if !filterFileExists(filter) {
                missingFilters.append(filter)
            }
        }
        if !missingFilters.isEmpty {
            DispatchQueue.main.async {
                self.showMissingFiltersSheet = true
            }
        } else {
            Task {
                await applyChanges()
            }
        }
    }

    
    private func filterFileExists(_ filter: FilterList) -> Bool {
        guard let containerURL = getSharedContainerURL() else { return false }
        let fileURL = containerURL.appendingPathComponent("\(filter.name).json")
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
    
    func applyChanges() async {
        showProgressView = true
        isUpdating = true
        progress = 0

        let selectedFilters = filterLists.filter { $0.isSelected }
        let totalSteps = Float(selectedFilters.count)
        var completedSteps: Float = 0

        var allRules: [[String: Any]] = []
        var advancedRules: [[String: Any]] = []

        for filter in selectedFilters {
            if !filterFileExists(filter) {
                let success = await fetchAndProcessFilter(filter)
                if !success {
                    appendLog("Failed to fetch and process filter: \(filter.name)")
                    continue
                }
            }

            if let (rules, advanced) = loadFilterRules(for: filter) {
                allRules.append(contentsOf: rules)
                if let advanced = advanced {
                    advancedRules.append(contentsOf: advanced)
                }
            }

            completedSteps += 1
            progress = completedSteps / totalSteps
        }

        saveBlockerList(allRules)
        saveAdvancedBlockerList(advancedRules)
        await reloadContentBlocker()

        DispatchQueue.main.async {
            self.hasUnappliedChanges = false
            self.isUpdating = false
            self.showProgressView = false
        }
    }
    
    private func loadFilterRules(for filter: FilterList) -> ([[String: Any]], [[String: Any]]?)? {
        guard let containerURL = getSharedContainerURL() else { return nil }
        let fileURL = containerURL.appendingPathComponent("\(filter.name).json")
        let advancedFileURL = containerURL.appendingPathComponent("\(filter.name)_advanced.json")
        
        do {
            let data = try Data(contentsOf: fileURL)
            let rules = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]]
            
            var advancedRules: [[String: Any]]? = nil
            if FileManager.default.fileExists(atPath: advancedFileURL.path) {
                let advancedData = try Data(contentsOf: advancedFileURL)
                advancedRules = try JSONSerialization.jsonObject(with: advancedData, options: []) as? [[String: Any]]
            }
            
            return (rules ?? [], advancedRules)
        } catch {
            appendLog("Error loading rules for \(filter.name): \(error)")
            return nil
        }
    }

    private func saveBlockerList(_ rules: [[String: Any]]) {
        guard let containerURL = getSharedContainerURL() else { return }
        let fileURL = containerURL.appendingPathComponent("blockerList.json")
        
        do {
            let data = try JSONSerialization.data(withJSONObject: rules, options: .prettyPrinted)
            try data.write(to: fileURL)
            appendLog("Successfully wrote blockerList.json")
        } catch {
            appendLog("Error saving blockerList.json: \(error)")
        }
    }
    
    private func saveAdvancedBlockerList(_ rules: [[String: Any]]) {
        guard let containerURL = getSharedContainerURL() else { return }
        let fileURL = containerURL.appendingPathComponent("advancedBlocking.json")
        
        do {
            let data = try JSONSerialization.data(withJSONObject: rules, options: .prettyPrinted)
            try data.write(to: fileURL)
            appendLog("Successfully wrote advancedBlocking.json")
        } catch {
            appendLog("Error saving advancedBlocking.json: \(error)")
        }
    }
    
    func updateMissingFilters() async {
        showProgressView = true
        isUpdating = true
        progress = 0
        
        let totalSteps = Float(missingFilters.count)
        var completedSteps: Float = 0
        
        for filter in missingFilters {
            let success = await fetchAndProcessFilter(filter)
            if success {
                missingFilters.removeAll { $0.id == filter.id }
            }
            completedSteps += 1
            progress = completedSteps / totalSteps
        }
        
        await applyChanges()
        isUpdating = false
    }
    
    private func fetchAndProcessFilter(_ filter: FilterList) async -> Bool {
        do {
            let (data, _) = try await URLSession.shared.data(from: filter.url)
            guard let content = String(data: data, encoding: .utf8) else {
                appendLog("Unable to parse content from \(filter.url)")
                return false
            }
            
            // Save raw content
            if let containerURL = getSharedContainerURL() {
                let rawFileURL = containerURL.appendingPathComponent("\(filter.name).txt")
                try content.write(to: rawFileURL, atomically: true, encoding: .utf8)
            }
            
            let rules = content.components(separatedBy: .newlines)
            let filteredRules = rules.filter { !$0.isEmpty && !$0.hasPrefix("!") && !$0.hasPrefix("[") }
            
            await convertAndSaveRules(filteredRules, for: filter)
            return true
        } catch {
            appendLog("Error fetching filter from \(filter.url): \(error.localizedDescription)")
            return false
        }
    }
    
    private func convertAndSaveRules(_ rules: [String], for filter: FilterList) async {
        do {
            let converter = ContentBlockerConverter()
            let result = converter.convertArray(
                rules: rules,
                safariVersion: .safari16_4,
                optimize: true,
                advancedBlocking: true
            )
            
            if let containerURL = getSharedContainerURL() {
                let fileURL = containerURL.appendingPathComponent("\(filter.name).json")
                let advancedFileURL = containerURL.appendingPathComponent("\(filter.name)_advanced.json")
                
                if let jsonData = result.converted.data(using: .utf8),
                   var jsonArray = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [[String: Any]] {
                    
                    jsonArray = Array(jsonArray.prefix(result.convertedCount))
                    let limitedJsonData = try JSONSerialization.data(withJSONObject: jsonArray, options: .prettyPrinted)
                    
                    try limitedJsonData.write(to: fileURL)
                    appendLog("Successfully wrote \(filter.name).json to: \(fileURL.path)")
                    
                    if let advancedData = result.advancedBlocking?.data(using: .utf8),
                       let advancedArray = try JSONSerialization.jsonObject(with: advancedData, options: []) as? [[String: Any]] {
                        let advancedJsonData = try JSONSerialization.data(withJSONObject: advancedArray, options: .prettyPrinted)
                        try advancedJsonData.write(to: advancedFileURL)
                        appendLog("Successfully wrote \(filter.name)_advanced.json to: \(advancedFileURL.path)")
                    }
                }
            }
        } catch {
            appendLog("ERROR: Failed to convert or save JSON for \(filter.name)")
            appendLog("Error details: \(error.localizedDescription)")
        }
    }
    
    private func enableFilter(_ filter: FilterList) {
        appendLog("Enabling filter: \(filter.name)")
    }
    
    private func getSharedContainerURL() -> URL? {
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier)
    }
    
    func reloadContentBlocker() async {
        guard let containerURL = getSharedContainerURL() else {
            appendLog("Error: Unable to access shared container")
            return
        }
        
        let fileURL = containerURL.appendingPathComponent("blockerList.json")
        
        do {
            let data = try Data(contentsOf: fileURL)
            if let jsonArray = try JSONSerialization.jsonObject(with: data, options: []) as? [[String: Any]] {
                let ruleCount = jsonArray.count
                appendLog("Attempting to reload content blocker with \(ruleCount) rules")
                
                try await SFContentBlockerManager.reloadContentBlocker(withIdentifier: contentBlockerIdentifier)
                appendLog("Content blocker reloaded successfully with \(ruleCount) rules")
            } else {
                appendLog("Error: Unable to parse blockerList.json")
            }
        } catch {
            appendLog("Error reloading content blocker: \(error)")
        }
    }
    
    func checkAndCreateBlockerList() {
        guard let containerURL = getSharedContainerURL() else {
            appendLog("Error: Unable to access shared container")
            return
        }
        
        let blockerListURL = containerURL.appendingPathComponent("blockerList.json")
        let advancedBlockingURL = containerURL.appendingPathComponent("advancedBlocking.json")
        
        if !FileManager.default.fileExists(atPath: blockerListURL.path) {
            appendLog("blockerList.json not found. Creating it...")
            let selectedFilters = filterLists.filter { $0.isSelected }
            var allRules: [[String: Any]] = []
            var advancedRules: [[String: Any]] = []
            
            for filter in selectedFilters {
                if let (rules, advanced) = loadFilterRules(for: filter) {
                    allRules.append(contentsOf: rules)
                    if let advanced = advanced {
                        advancedRules.append(contentsOf: advanced)
                    }
                }
            }
            
            saveBlockerList(allRules)
            saveAdvancedBlockerList(advancedRules)
        } else {
            appendLog("blockerList.json found.")
        }
    }
    
    func toggleFilterListSelection(id: UUID) {
        if let index = filterLists.firstIndex(where: { $0.id == id }) {
            filterLists[index].isSelected.toggle()
            saveSelectedState()
            hasUnappliedChanges = true
        }
    }
    
    func filterLists(for category: FilterListCategory) -> [FilterList] {
        category == .all ? filterLists : filterLists.filter { $0.category == category }
    }
    
    func appendLog(_ message: String) {
        logs += message + "\n"
        saveLogsToFile()
    }
    
    private func saveLogsToFile() {
        guard let containerURL = getSharedContainerURL() else { return }
        let fileURL = containerURL.appendingPathComponent("logs.txt")
        
        do {
            try logs.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving logs: \(error)")
        }
    }
    
    func loadLogsFromFile() {
        guard let containerURL = getSharedContainerURL() else { return }
        let fileURL = containerURL.appendingPathComponent("logs.txt")
        
        do {
            logs = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            print("Error loading logs: \(error)")
        }
    }
    
    func clearLogs() {
        logs = ""
        saveLogsToFile()
    }
    
    func checkForUpdates() async {
        availableUpdates.removeAll()
        for filter in filterLists {
            if await hasUpdate(for: filter) {
                availableUpdates.append(filter)
            }
        }
        if !availableUpdates.isEmpty {
            DispatchQueue.main.async {
                self.showingUpdatePopup = true
            }
        } else {
            appendLog("No updates available.")
        }
    }

    private func hasUpdate(for filter: FilterList) async -> Bool {
        guard let containerURL = getSharedContainerURL() else { return false }
        let fileURL = containerURL.appendingPathComponent("\(filter.name).txt")
        
        do {
            let (data, _) = try await URLSession.shared.data(from: filter.url)
            let onlineContent = String(data: data, encoding: .utf8) ?? ""
            
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let localContent = try String(contentsOf: fileURL, encoding: .utf8)
                return onlineContent != localContent
            } else {
                return true // If local file doesn't exist, consider it as needing an update
            }
        } catch {
            appendLog("Error checking update for \(filter.name): \(error)")
            return false
        }
    }

    func updateSelectedFilters(_ selectedFilters: [FilterList]) async {
        showProgressView = true
        isUpdating = true
        progress = 0
        
        let totalSteps = Float(selectedFilters.count)
        var completedSteps: Float = 0
        
        for filter in selectedFilters {
            let success = await fetchAndProcessFilter(filter)
            if success {
                if let index = availableUpdates.firstIndex(where: { $0.id == filter.id }) {
                    availableUpdates.remove(at: index)
                }
                appendLog("Successfully updated \(filter.name)")
            } else {
                appendLog("Failed to update \(filter.name)")
            }
            completedSteps += 1
            progress = completedSteps / totalSteps
        }
        
        await applyChanges()
        isUpdating = false
        showProgressView = false
    }
    
    // Make sure you're not running the app without filters on!
    func checkForEnabledFilters() {
        let enabledFilters = filterLists.filter { $0.isSelected }
        if enabledFilters.isEmpty {
            showRecommendedFiltersAlert = true
        }
    }

    func enableRecommendedFilters() {
        let recommendedFilters = [
            "AdGuard Base filter",
            "AdGuard Tracking Protection filter",
            "AdGuard Annoyances filter",
            "EasyPrivacy",
            "Online Malicious URL Blocklist",
            "d3Host List by d3ward",
            "Anti-Adblock List"
        ]

        for index in filterLists.indices {
            if recommendedFilters.contains(filterLists[index].name) {
                filterLists[index].isSelected = true
                appendLog("Enabled recommended filter: \(filterLists[index].name)")
            }
        }
        saveSelectedState()
        hasUnappliedChanges = true
        appendLog("Recommended filters have been enabled")
        
        // After enabling recommended filters, check for missing filters
        checkAndEnableFilters()
    }
    
    private func checkAndCreateGroupFolder() {
        guard let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedContainerIdentifier) else {
            appendLog("Error: Unable to access shared container")
            return
        }
        
        if !FileManager.default.fileExists(atPath: containerURL.path) {
            do {
                try FileManager.default.createDirectory(at: containerURL, withIntermediateDirectories: true, attributes: nil)
                appendLog("Created group folder: \(containerURL.path)")
            } catch {
                appendLog("Error creating group folder: \(error.localizedDescription)")
            }
        } else {
            appendLog("Group folder already exists: \(containerURL.path)")
        }
    }
}
