import SwiftUI

/// A starter-template chooser shown in `MermaidEditorView` when the note body is empty.
/// Tapping a chip writes the template into `editableContent`; once content is non-empty
/// the chooser is replaced by the live preview pane.
struct MermaidStarterChooser: View {
    /// Invoked with the raw Mermaid source when the user taps a template.
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                MermaidStarterFlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(MermaidSampleDiagram.all) { sample in
                        Button {
                            onSelect(sample.content)
                        } label: {
                            chipLabel(sample)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(sample.name)
                        .accessibilityHint(String(
                            localized: "Inserts a sample \(sample.name) diagram into the editor.",
                            comment: "Mermaid starter chooser chip a11y hint"
                        ))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "Start with a template", comment: "Mermaid starter chooser title"))
                .font(.headline)
            Text(String(
                localized: "Tap a diagram type to insert a sample you can edit. The preview will replace this panel once there's content.",
                comment: "Mermaid starter chooser subtitle"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func chipLabel(_ sample: MermaidSampleDiagram) -> some View {
        HStack(spacing: 6) {
            Image(systemName: sample.iconName)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            Text(sample.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        )
    }
}

// MARK: - Sample diagrams

struct MermaidSampleDiagram: Identifiable, Sendable {
    let id: String
    let name: String
    let iconName: String
    let content: String

    init(id: String, name: String, iconName: String, content: String) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.content = content
    }
}

extension MermaidSampleDiagram {
    /// One short example per diagram type, written for this app. The most common types come first.
    static let all: [MermaidSampleDiagram] = [
        MermaidSampleDiagram(
            id: "flowchart",
            name: String(localized: "Flowchart", comment: "Mermaid sample diagram name"),
            iconName: "arrow.triangle.branch",
            content: """
            flowchart TD
                Idea[Idea for a note] --> Where{Where does it belong?}
                Where -->|Project| Project[Add to project notes]
                Where -->|Someday| Inbox[Drop in inbox]
                Where -->|Not sure| Tag[Tag it #review]
                Project --> Done((Saved))
                Inbox --> Done
                Tag --> Done
            """
        ),
        MermaidSampleDiagram(
            id: "sequence",
            name: String(localized: "Sequence", comment: "Mermaid sample diagram name"),
            iconName: "arrow.left.arrow.right",
            content: """
            sequenceDiagram
                actor Reader
                participant App
                participant Server
                Reader->>App: Open note
                App->>Server: Fetch latest version
                Server-->>App: Note content
                App-->>Reader: Show note
                Reader->>App: Edit and save
                App->>Server: Upload changes
                Server-->>App: Saved
            """
        ),
        MermaidSampleDiagram(
            id: "class",
            name: String(localized: "Class", comment: "Mermaid sample diagram name"),
            iconName: "square.stack.3d.up",
            content: """
            classDiagram
                class Notebook {
                    +String title
                    +addNote(Note note)
                }
                class Note {
                    +String title
                    +String body
                    +Date modified
                    +rename(String title)
                }
                class Tag {
                    +String name
                }
                Notebook "1" o-- "*" Note : contains
                Note "*" -- "*" Tag : labelled with
            """
        ),
        MermaidSampleDiagram(
            id: "state",
            name: String(localized: "State", comment: "Mermaid sample diagram name"),
            iconName: "circle.dotted",
            content: """
            stateDiagram-v2
                [*] --> Draft
                Draft --> Review : ready
                Review --> Draft : changes needed
                Review --> Published : approved
                Published --> Archived : outdated
                Archived --> [*]
            """
        ),
        MermaidSampleDiagram(
            id: "er",
            name: String(localized: "Entity Relationship", comment: "Mermaid sample diagram name"),
            iconName: "tablecells",
            content: """
            erDiagram
                AUTHOR ||--o{ BOOK : writes
                BOOK ||--|{ CHAPTER : has
                BOOK }o--o{ GENRE : "belongs to"
                AUTHOR {
                    string name
                    int born
                }
                BOOK {
                    string title
                    int year
                }
                CHAPTER {
                    int number
                    string heading
                }
                GENRE {
                    string name
                }
            """
        ),
        MermaidSampleDiagram(
            id: "pie",
            name: String(localized: "Pie", comment: "Mermaid sample diagram name"),
            iconName: "chart.pie",
            content: """
            pie title Where my week went
                "Work" : 40
                "Sleep" : 56
                "Family" : 30
                "Sport" : 6
                "Reading" : 8
            """
        ),
        MermaidSampleDiagram(
            id: "mindmap",
            name: String(localized: "Mind Map", comment: "Mermaid sample diagram name"),
            iconName: "brain",
            content: """
            mindmap
              root((Garden))
                Vegetables
                  Tomatoes
                  Beans
                  Courgettes
                Herbs
                  Basil
                  Mint
                Jobs
                  Watering
                  Weeding
                  Compost
            """
        ),
        MermaidSampleDiagram(
            id: "gantt",
            name: String(localized: "Gantt", comment: "Mermaid sample diagram name"),
            iconName: "calendar.badge.clock",
            content: """
            gantt
                title Kitchen renovation
                dateFormat YYYY-MM-DD
                section Preparation
                    Choose design     :done,    design, 2026-03-01, 14d
                    Order cabinets    :done,    order,  after design, 3d
                section Work
                    Remove old kitchen :active, demo, 2026-04-06, 4d
                    Plumbing and power :        wires, after demo, 5d
                    Install cabinets   :        fit, after wires, 6d
                section Finish
                    Paint and tiles    :        paint, after fit, 5d
            """
        ),
        MermaidSampleDiagram(
            id: "timeline",
            name: String(localized: "Timeline", comment: "Mermaid sample diagram name"),
            iconName: "clock",
            content: """
            timeline
                title History of the bicycle
                1817 : Running machine without pedals
                1860s : Pedals on the front wheel
                1885 : Chain-driven safety bicycle
                1888 : Air-filled tyres
                1990s : Electric bikes appear
            """
        ),
        MermaidSampleDiagram(
            id: "kanban",
            name: String(localized: "Kanban", comment: "Mermaid sample diagram name"),
            iconName: "rectangle.split.3x1",
            content: """
            kanban
                todo[To do]
                    t1[Book train tickets]
                    t2[Renew passport]@{ priority: 'High' }
                doing[In progress]
                    t3[Plan the route]@{ assigned: 'Sam' }
                done[Done]
                    t4[Pick the dates]
                    t5[Ask for time off]
            """
        ),
        MermaidSampleDiagram(
            id: "git",
            name: String(localized: "Git Graph", comment: "Mermaid sample diagram name"),
            iconName: "point.3.connected.trianglepath.dotted",
            content: """
            gitGraph
                commit id: "first draft"
                branch photos
                checkout photos
                commit id: "add photos"
                checkout main
                commit id: "fix typos"
                merge photos
                branch translation
                checkout translation
                commit id: "dutch version"
                checkout main
                merge translation
                commit id: "publish"
            """
        ),
        MermaidSampleDiagram(
            id: "user-journey",
            name: String(localized: "User Journey", comment: "Mermaid sample diagram name"),
            iconName: "figure.walk",
            content: """
            journey
                title Morning commute
                section Leave home
                    Pack bag: 3: Me
                    Find keys: 1: Me
                section Travel
                    Catch the train: 4: Me
                    Read on the train: 5: Me
                section Arrive
                    Get coffee: 5: Me, Colleague
            """
        ),
        MermaidSampleDiagram(
            id: "quadrant",
            name: String(localized: "Quadrant", comment: "Mermaid sample diagram name"),
            iconName: "square.split.2x2",
            content: """
            quadrantChart
                title Weekend tasks
                x-axis Low effort --> High effort
                y-axis Low value --> High value
                quadrant-1 Plan it
                quadrant-2 Do it now
                quadrant-3 Skip it
                quadrant-4 Delegate
                Clean the gutters: [0.75, 0.55]
                Call grandma: [0.2, 0.9]
                Sort old cables: [0.35, 0.2]
                Paint the fence: [0.85, 0.7]
                Water the plants: [0.1, 0.6]
            """
        ),
        MermaidSampleDiagram(
            id: "xy",
            name: String(localized: "XY Chart", comment: "Mermaid sample diagram name"),
            iconName: "chart.xyaxis.line",
            content: """
            xychart-beta
                title "Kilometres cycled per month"
                x-axis [Jan, Feb, Mar, Apr, May, Jun]
                y-axis "Kilometres" 0 --> 400
                bar [80, 95, 160, 210, 300, 340]
                line [80, 95, 160, 210, 300, 340]
            """
        ),
        MermaidSampleDiagram(
            id: "sankey",
            name: String(localized: "Sankey", comment: "Mermaid sample diagram name"),
            iconName: "arrow.right.to.line.compact",
            content: """
            sankey-beta

            Salary,Housing,1100
            Salary,Groceries,450
            Salary,Transport,180
            Salary,Savings,400
            Salary,Leisure,270
            Leisure,Eating out,150
            Leisure,Hobbies,120
            """
        ),
        MermaidSampleDiagram(
            id: "treemap",
            name: String(localized: "Treemap", comment: "Mermaid sample diagram name"),
            iconName: "square.grid.2x2",
            content: """
            treemap-beta
            "Photos"
                "2025": 40
                "2026"
                    "Holiday": 25
                    "Family": 18
            "Documents"
                "Taxes": 6
                "Manuals": 4
            "Music": 30
            """
        ),
        MermaidSampleDiagram(
            id: "treeview",
            name: String(localized: "Tree View", comment: "Mermaid sample diagram name"),
            iconName: "list.bullet.indent",
            content: """
            treeView-beta
                "Recipes"
                    "Breakfast"
                        "Pancakes"
                        "Overnight oats"
                    "Dinner"
                        "Lasagne"
                        "Vegetable curry"
                    "Shopping list"
            """
        ),
        MermaidSampleDiagram(
            id: "venn",
            name: String(localized: "Venn", comment: "Mermaid sample diagram name"),
            iconName: "circle.circle",
            content: """
            venn-beta
                title Pets we like
                set Cats
                    text Quiet
                    text Independent
                set Dogs
                    text Loyal
                    text Playful
                union Cats,Dogs["Cuddly"]
            """
        ),
        MermaidSampleDiagram(
            id: "ishikawa",
            name: String(localized: "Ishikawa", comment: "Mermaid sample diagram name"),
            iconName: "fish",
            content: """
            ishikawa-beta
                Bread did not rise
                    Ingredients
                        Old yeast
                        Too much salt
                    Method
                        Not kneaded long enough
                        Dough too dry
                    Environment
                        Kitchen too cold
                    Time
                        Proved too briefly
            """
        ),
        MermaidSampleDiagram(
            id: "wardley",
            name: String(localized: "Wardley", comment: "Mermaid sample diagram name"),
            iconName: "map",
            content: """
            wardley-beta
                title Home coffee

                anchor Me [0.95, 0.5]

                component Morning coffee [0.8, 0.45]
                component Beans [0.6, 0.75]
                component Grinder [0.5, 0.4]
                component Espresso machine [0.45, 0.55]
                component Electricity [0.2, 0.9]

                Me -> Morning coffee
                Morning coffee -> Beans
                Morning coffee -> Grinder
                Morning coffee -> Espresso machine
                Grinder -> Electricity
                Espresso machine -> Electricity
            """
        ),
        MermaidSampleDiagram(
            id: "architecture",
            name: String(localized: "Architecture", comment: "Mermaid sample diagram name"),
            iconName: "building.2",
            content: """
            architecture-beta
                group home(cloud)[Home network]

                service phone(internet)[Phone]
                service router(server)[Router] in home
                service nas(disk)[NAS] in home
                service notes(database)[Notes server] in home

                phone:R -- L:router
                router:R -- L:notes
                notes:B -- T:nas
            """
        ),
        MermaidSampleDiagram(
            id: "block",
            name: String(localized: "Block", comment: "Mermaid sample diagram name"),
            iconName: "rectangle.stack",
            content: """
            block-beta
            columns 3
                Inbox["Inbox"] Sort["Sort"] Archive["Archive"]
                space:3
                Read["Read later"]:3
                Inbox --> Sort
                Sort --> Archive
                Sort --> Read
            """
        ),
        MermaidSampleDiagram(
            id: "c4",
            name: String(localized: "C4 Context", comment: "Mermaid sample diagram name"),
            iconName: "building.columns",
            content: """
            C4Context
                title Notes app in context
                Person(user, "Note taker", "Writes and reads notes on phone and laptop.")
                System(app, "Notes app", "Shows, edits and searches notes.")
                System_Ext(server, "Notes server", "Stores every note and syncs devices.")
                System_Ext(mail, "E-mail", "Sends sign-in links.")

                Rel(user, app, "Uses")
                Rel(app, server, "Reads and writes notes", "HTTPS")
                Rel(server, mail, "Sends messages through")
            """
        ),
        MermaidSampleDiagram(
            id: "radar",
            name: String(localized: "Radar", comment: "Mermaid sample diagram name"),
            iconName: "scope",
            content: """
            ---
            title: "Holiday destinations"
            ---
            radar-beta
                axis w["Weather"], f["Food"], c["Culture"]
                axis n["Nature"], p["Price"], t["Travel time"]
                curve a["Lisbon"]{8, 9, 8, 6, 7, 7}
                curve b["Oslo"]{4, 6, 7, 9, 3, 6}

                max 10
                min 0
            """
        ),
        MermaidSampleDiagram(
            id: "packet",
            name: String(localized: "Packet", comment: "Mermaid sample diagram name"),
            iconName: "rectangle.grid.1x2",
            content: """
            ---
            title: "Example message header"
            ---
            packet
            0-7: "Version"
            8-15: "Type"
            16-31: "Length"
            32-63: "Message ID"
            64-95: "Timestamp"
            96-127: "Payload (variable)"
            """
        ),
        MermaidSampleDiagram(
            id: "requirement",
            name: String(localized: "Requirement", comment: "Mermaid sample diagram name"),
            iconName: "checklist",
            content: """
            requirementDiagram

                requirement offline_reading {
                    id: 1
                    text: Notes opened before stay readable without a connection.
                    risk: medium
                    verifymethod: test
                }

                element local_cache {
                    type: component
                }

                local_cache - satisfies -> offline_reading
            """
        ),
    ]
}

// MARK: - Flow layout for chips

/// Minimal flow layout: places children left-to-right and wraps to a new row when the next child
/// would overflow the proposed width. Keeps the chooser usable on iPhone widths without resorting
/// to a fixed-column grid (which would either truncate long names or waste horizontal space).
private struct MermaidStarterFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(0) { acc, row in
            let rowHeight = row.map(\.size.height).max() ?? 0
            return acc + rowHeight
        } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        let width = rows.map { row in
            row.reduce(0) { $0 + $1.size.width } + CGFloat(max(0, row.count - 1)) * spacing
        }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        let rows = computeRows(subviews: subviews, maxWidth: maxWidth)
        var y = bounds.minY
        for row in rows {
            let rowHeight = row.map(\.size.height).max() ?? 0
            var x = bounds.minX
            for entry in row {
                subviews[entry.index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(entry.size)
                )
                x += entry.size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }

    private struct Entry {
        let index: Int
        let size: CGSize
    }

    private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [[Entry]] {
        var rows: [[Entry]] = [[]]
        var currentRowWidth: CGFloat = 0
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let neededWidth = size.width + (rows[rows.count - 1].isEmpty ? 0 : spacing)
            if currentRowWidth + neededWidth > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentRowWidth = 0
            }
            rows[rows.count - 1].append(Entry(index: i, size: size))
            currentRowWidth += size.width + (rows[rows.count - 1].count > 1 ? spacing : 0)
        }
        return rows
    }
}
