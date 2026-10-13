import SwiftUI
import AppKit

// Use the native outline view's single drag session for both grouping and ordering.
struct NativeProjectSidebar: NSViewRepresentable {
    @ObservedObject var store: AppStore
    @Binding var selectedFolderID: UUID?
    var editFolder: (ProjectFolder?, UUID?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        let outline = ProjectOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("projects"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.backgroundColor = .clear
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.intercellSpacing = NSSize(width: 0, height: 4)
        outline.indentationPerLevel = 14
        outline.autoresizingMask = [.width]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.registerForDraggedTypes([Coordinator.projectType, Coordinator.folderType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.contextMenuForRow = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        scroll.documentView = outline
        context.coordinator.outline = outline
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.reload()
    }

    final class Node: NSObject {
        enum Kind { case root, project(UUID), folder(UUID) }
        let kind: Kind
        init(_ kind: Kind) { self.kind = kind }
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let projectType = NSPasteboard.PasteboardType("at.ac.vbc.cbe.Pinna2HRTF.sidebar-project")
        static let folderType = NSPasteboard.PasteboardType("at.ac.vbc.cbe.Pinna2HRTF.sidebar-folder")
        var parent: NativeProjectSidebar
        weak var outline: NSOutlineView?
        let root = Node(.root)
        var projectNodes: [UUID: Node] = [:]
        var folderNodes: [UUID: Node] = [:]
        var updating = false
        var displayedProjects: [ProjectRecord] = []
        var displayedFolders: [ProjectFolder] = []
        var displayedStages: [UUID: Stage] = [:]
        var lastRevealToken: UUID?

        init(_ parent: NativeProjectSidebar) { self.parent = parent }

        func children(of item: Any?) -> [Node] {
            guard let node = item as? Node else {
                return [root] + parent.store.projects.filter { $0.folderID == nil }.compactMap { projectNodes[$0.id] }
                    + parent.store.folders.compactMap { folderNodes[$0.id] }
            }
            switch node.kind {
            case .root: return []
            case let .folder(id):
                return parent.store.projects.filter { $0.folderID == id }.compactMap { projectNodes[$0.id] }
            case .project: return []
            }
        }

        func reload() {
            guard let outline else { return }
            updating = true
            defer { updating = false }
            let changed = projectNodes.isEmpty || displayedProjects != parent.store.projects
                || displayedFolders != parent.store.folders || displayedStages != parent.store.runningStages
            if changed {
                displayedProjects = parent.store.projects
                displayedFolders = parent.store.folders
                displayedStages = parent.store.runningStages
                projectNodes = Dictionary(uniqueKeysWithValues: parent.store.projects.map { ($0.id, projectNodes[$0.id] ?? Node(.project($0.id))) })
                folderNodes = Dictionary(uniqueKeysWithValues: parent.store.folders.map { ($0.id, folderNodes[$0.id] ?? Node(.folder($0.id))) })
                outline.reloadData()
                for folder in parent.store.folders {
                    guard let node = folderNodes[folder.id] else { continue }
                    if folder.isExpanded { outline.expandItem(node) } else { outline.collapseItem(node) }
                }
            }
            if let id = parent.selectedFolderID, let node = folderNodes[id], outline.row(forItem: node) >= 0 {
                let row = outline.row(forItem: node)
                if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            } else if let id = parent.store.selectedProjectID, let node = projectNodes[id], outline.row(forItem: node) >= 0 {
                let row = outline.row(forItem: node)
                if outline.selectedRow != row { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                if lastRevealToken != parent.store.projectRevealToken {
                    outline.scrollRowToVisible(row)
                    lastRevealToken = parent.store.projectRevealToken
                }
            } else {
                outline.deselectAll(nil)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children(of: item).count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { children(of: item)[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            if case .folder = node.kind { return true }
            return false
        }
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            (item as? Node) === root
        }
        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool { (item as? Node) !== root }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let node = item as? Node else { return false }
            switch node.kind {
            case .project, .folder: return true
            case .root: return false
            }
        }
        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            guard let node = item as? Node else { return 30 }
            if case .project = node.kind { return 40 }
            return 28
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node else { return nil }
            let view: AnyView
            switch node.kind {
            case .root:
                view = AnyView(Text("Projects").font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading))
            case let .folder(id):
                guard let folder = parent.store.folders.first(where: { $0.id == id }) else { return nil }
                view = AnyView(Label(folder.name, systemImage: "folder.fill").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading))
            case let .project(id):
                guard let project = parent.store.projects.first(where: { $0.id == id }) else { return nil }
                view = AnyView(ProjectRow(project: project, runningStage: parent.store.runningStages[id]))
            }
            let hosting = SidebarRowHostingView(rootView: view)
            hosting.toolTip = {
                if case .root = node.kind { return "Drop a project here to move it out of a folder" }
                if case .folder = node.kind { return "Drop a project here to move it into this folder" }
                return nil
            }()
            return hosting
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, let node = outline.item(atRow: outline.selectedRow) as? Node else { return }
            switch node.kind {
            case let .folder(id):
                parent.selectedFolderID = id
            case let .project(id):
                parent.selectedFolderID = nil
                if parent.store.selectedProjectID != id {
                    parent.store.selectedProjectID = id
                    parent.store.persist()
                }
            case .root: break
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { saveExpansion(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { saveExpansion(notification, expanded: false) }
        func saveExpansion(_ notification: Notification, expanded: Bool) {
            guard !updating, let node = notification.userInfo?["NSObject"] as? Node,
                  case let .folder(id) = node.kind,
                  let index = parent.store.folders.firstIndex(where: { $0.id == id }) else { return }
            parent.store.folders[index].isExpanded = expanded
            parent.store.persist()
        }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard let node = item as? Node else { return nil }
            let pasteboard = NSPasteboardItem()
            switch node.kind {
            case let .project(id): pasteboard.setString(id.uuidString, forType: Self.projectType)
            case let .folder(id): pasteboard.setString(id.uuidString, forType: Self.folderType)
            case .root: return nil
            }
            return pasteboard
        }
        func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
            guard let source = info.draggingSource as? NSOutlineView, source === outlineView else { return [] }
            if let value = info.draggingPasteboard.string(forType: Self.projectType), let id = UUID(uuidString: value), projectNodes[id] != nil {
                if let node = item as? Node, case .project = node.kind { return [] }
                return .move
            }
            if let value = info.draggingPasteboard.string(forType: Self.folderType), let id = UUID(uuidString: value), folderNodes[id] != nil,
               (item == nil || (item as? Node) === root), index >= 0 { return .move }
            return []
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
            guard !self.outlineView(outlineView, validateDrop: info, proposedItem: item, proposedChildIndex: index).isEmpty else { return false }
            if let value = info.draggingPasteboard.string(forType: Self.projectType), let id = UUID(uuidString: value) {
                var folderID: UUID?
                if let node = item as? Node, case let .folder(folder) = node.kind { folderID = folder }
                let siblings = children(of: item)
                var beforeID: UUID?
                if index >= 0 && index < siblings.count, case let .project(destination) = siblings[index].kind { beforeID = destination }
                parent.store.moveProject(id, toFolder: folderID, before: beforeID)
                // A drop at the end of a group should append within that group.
                if beforeID == nil, let sourceIndex = parent.store.projects.firstIndex(where: { $0.id == id }) {
                    let moved = parent.store.projects.remove(at: sourceIndex)
                    let last = parent.store.projects.lastIndex(where: { $0.folderID == folderID })
                    parent.store.projects.insert(moved, at: last.map { $0 + 1 } ?? parent.store.projects.endIndex)
                    parent.store.persist()
                }
                return true
            }
            if let value = info.draggingPasteboard.string(forType: Self.folderType), let id = UUID(uuidString: value),
               let source = parent.store.folders.firstIndex(where: { $0.id == id }) {
                let rootProjectCount = parent.store.projects.filter { $0.folderID == nil }.count
                let destination = max(0, min(parent.store.folders.count, index - rootProjectCount - 1))
                parent.store.folders.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                parent.store.persist()
                return true
            }
            return false
        }

        private final class MenuAction: NSObject {
            let action: () -> Void
            init(_ action: @escaping () -> Void) { self.action = action }
        }
        @objc func performMenuAction(_ sender: NSMenuItem) { (sender.representedObject as? MenuAction)?.action() }
        func add(_ title: String, to menu: NSMenu, enabled: Bool = true, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.representedObject = MenuAction(action)
            menu.addItem(item)
        }
        func contextMenu(forRow row: Int) -> NSMenu? {
            guard let outline, row >= 0, let node = outline.item(atRow: row) as? Node else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            switch node.kind {
            case .root:
                add("New Project", to: menu) { self.parent.store.createProject() }
                add("New Folder…", to: menu) { self.parent.editFolder(nil, nil) }
            case let .folder(id):
                guard let folder = parent.store.folders.first(where: { $0.id == id }) else { return nil }
                add("Rename Folder…", to: menu) { self.parent.editFolder(folder, nil) }
                add("New Project in Folder", to: menu) {
                    self.parent.store.createProject()
                    if let projectID = self.parent.store.selectedProjectID { self.parent.store.moveProject(projectID, toFolder: id) }
                }
                add("Remove Folder", to: menu) {
                    if self.parent.selectedFolderID == id { self.parent.selectedFolderID = nil }
                    self.parent.store.removeFolder(id)
                }
            case let .project(id):
                let move = NSMenuItem(title: "Move to Folder", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                add("No Folder", to: submenu) { self.parent.store.moveProject(id, toFolder: nil) }
                for folder in parent.store.folders {
                    add(folder.name, to: submenu) { self.parent.store.moveProject(id, toFolder: folder.id) }
                }
                submenu.addItem(.separator())
                add("New Folder…", to: submenu) { self.parent.editFolder(nil, id) }
                move.submenu = submenu
                menu.addItem(move)
                add("Duplicate Project", to: menu) { self.parent.store.selectedProjectID = id; self.parent.store.duplicateSelectedProject() }
                add("Remove Project", to: menu, enabled: parent.store.canRemoveProject(id)) { self.parent.store.selectedProjectID = id; self.parent.store.forgetSelectedProject() }
            }
            return menu
        }
    }
}

// Resolve the clicked row before constructing the menu.
private final class ProjectOutlineView: NSOutlineView {
    var contextMenuForRow: ((Int) -> NSMenu?)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return contextMenuForRow?(row(at: point))
    }
}

// Row content is display-only; let the outline view handle mouse selection and dragging.
private final class SidebarRowHostingView: NSHostingView<AnyView> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
