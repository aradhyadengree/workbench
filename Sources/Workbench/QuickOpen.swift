import SwiftUI

enum ProjectFiles {
    static func paths(in folder: URL) -> [String] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants]
        ) else { return [] }
        
        let ignored: Set<String> = [
            ".git", ".build", ".swiftpm", "node_modules", "DerivedData",
            ".venv", "__pycache__", ".next", "target", "dist", ".DS_Store"
        ]
        var paths: [String] = []
        for case let url as URL in walker {
            if Task.isCancelled { return [] }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isDirectory == true {
                if ignored.contains(url.lastPathComponent) || values.isSymbolicLink == true {
                    walker.skipDescendants()
                }
            } else if values.isRegularFile == true {
                paths.append(url.pathComponents.suffix(walker.level).joined(separator: "/"))
            }
        }
        return paths.sorted()
    }

    static func changedPaths(in folder: URL) throws -> [String] {
        func git(_ args: [String]) throws -> [String] {
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.currentDirectoryURL = folder
            process.arguments = args
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw CocoaError(.fileReadUnknown) }
            return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        }
        let working = try git(["ls-files", "-z", "--modified", "--others", "--exclude-standard", "--", "."])
        let staged = try git(["diff", "--cached", "--relative", "--name-only", "--diff-filter=ACMRT", "-z", "--", "."])
        return Set(working + staged).filter { path in
            (try? folder.appendingPathComponent(path).resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted()
    }

    static func matches(_ query: String, in paths: [String]) -> [String] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if term.isEmpty { return Array(paths.prefix(80)) }
        var names: [String] = [], others: [String] = []
        for path in paths where path.localizedCaseInsensitiveContains(term) {
            if (path as NSString).lastPathComponent.lowercased().hasPrefix(term.lowercased()) {
                names.append(path)
                if names.count == 80 { break }
            } else if others.count < 80 {
                others.append(path)
            }
        }
        return Array((names + others).prefix(80))
    }
}

struct QuickOpen: View {
    let project: Project
    let opened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var typing: Bool
    @State private var paths: [String] = []
    @State private var query = ""
    @State private var selection = 0
    @State private var changed = false
    @State private var issue = ""
    @State private var loading = true

    private func pick(_ path: String) {
        let url = project.folder.appendingPathComponent(path)
        project.open(url)
        if project.selected == url {
            opened()
            dismiss()
        }
    }

    var body: some View {
        let results = ProjectFiles.matches(query, in: paths)
        VStack(spacing: 0) {
            // Search Input Header
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(WorkbenchTheme.toolColor(.editor))

                TextField("Search files by name or path…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($typing)
                    .onSubmit {
                        if results.indices.contains(selection) {
                            pick(results[selection])
                        }
                    }

                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }

                Button("Esc") { dismiss() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)

            // Scope Selector
            Picker("File scope", selection: $changed) {
                Text("All Files (\(paths.count))").tag(false)
                Text("Git Changes").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .background(colorScheme == .dark ? WorkbenchTheme.darkSurface : WorkbenchTheme.lightSurface)

            Divider()

            // Results List
            if loading || results.isEmpty {
                VStack(spacing: 8) {
                    if loading {
                        ProgressView().controlSize(.small)
                        Text("Indexing project files…").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text(issue.isEmpty ? "No files matching “\(query)”" : issue)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(Array(results.enumerated()), id: \.element) { index, path in
                                let fileName = (path as NSString).lastPathComponent
                                let presentation = WorkbenchTheme.filePresentation(for: fileName, isDirectory: false)
                                let isSelected = (index == selection)
                                let gitStatus = project.gitStatuses[path]

                                Button {
                                    pick(path)
                                } label: {
                                    HStack(spacing: 8) {
                                        // Colored File Icon
                                        Image(systemName: presentation.icon)
                                            .font(.system(size: 13))
                                            .foregroundStyle(presentation.color)
                                            .frame(width: 20)

                                        // File Name & Path
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(fileName)
                                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                                                .foregroundStyle(isSelected ? Color.white : Color.primary)

                                            Text(path)
                                                .font(.system(size: 11))
                                                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                                                .truncationMode(.middle)
                                        }

                                        Spacer()

                                        // Git Status Pill
                                        if let status = gitStatus {
                                            Text(status.rawValue)
                                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(
                                                    (status == .modified ? Color.orange : Color.green).opacity(0.2),
                                                    in: RoundedRectangle(cornerRadius: 3)
                                                )
                                                .foregroundStyle(status == .modified ? Color.orange : Color.green)
                                        }

                                        if isSelected {
                                            Image(systemName: "return")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundStyle(.white.opacity(0.8))
                                        }
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(
                                        isSelected ? Color.accentColor : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    )
                                }
                                .buttonStyle(.plain)
                                .id(index)
                            }
                        }
                        .padding(6)
                    }
                    .background(colorScheme == .dark ? WorkbenchTheme.darkBackground : WorkbenchTheme.lightBackground)
                    .onChange(of: selection) { proxy.scrollTo(selection) }
                }
            }
        }
        .frame(width: 540, height: 380)
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(colorScheme == .dark ? WorkbenchTheme.darkBorder : WorkbenchTheme.lightBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: query) { selection = 0 }
        .onMoveCommand { move in
            if move == .down { selection = min(selection + 1, max(results.count - 1, 0)) }
            if move == .up { selection = max(0, selection - 1) }
        }
        .task(id: changed) {
            loading = true
            selection = 0
            issue = ""
            paths = []
            typing = true
            let folder = project.folder
            let onlyChanges = changed
            let worker = Task.detached(priority: .userInitiated) { () -> [String]? in
                if onlyChanges { return try? ProjectFiles.changedPaths(in: folder) }
                return ProjectFiles.paths(in: folder)
            }
            let indexed = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled {
                paths = indexed ?? []
                loading = false
                if indexed == nil { issue = "Open a Git working tree to see changed files." }
            }
        }
    }
}
