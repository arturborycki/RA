//
//  TreeView.swift
//  RelationalAlgebra
//
//  The visual operator-tree representation of the relational-algebra
//  expression. Panning and pinch-to-zoom are supported; the diagram is laid out
//  by `TreeLayout` and drawn as edges (Canvas) + node bubbles.
//

import SwiftUI

struct TreeView: View {
    /// The tree to draw — an algebra operator tree or a calculus scope tree;
    /// `DiagramNode` carries no notation-specific structure, so one view serves
    /// both.
    let root: DiagramNode?
    @State private var zoom: CGFloat = 1.0
    @GestureState private var pinch: CGFloat = 1.0

    var body: some View {
        if let root {
            let layout = TreeLayout(root: root)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    EdgeCanvas(edges: layout.edges, size: layout.size)
                    ForEach(layout.nodes) { positioned in
                        NodeBubble(node: positioned.node, size: positioned.size)
                            .position(positioned.center)
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height)
                .scaleEffect(zoom * pinch, anchor: .topLeading)
                .frame(width: layout.size.width * zoom * pinch,
                       height: layout.size.height * zoom * pinch,
                       alignment: .topLeading)
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .gesture(
                MagnificationGesture()
                    .updating($pinch) { value, state, _ in state = value }
                    .onEnded { value in
                        zoom = min(max(zoom * value, 0.4), 3.0)
                    }
            )
            .overlay(alignment: .bottomTrailing) { zoomControls }
        } else {
            EmptyResultView(systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            message: "The operator tree appears here once the SQL parses.")
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 0) {
            Button { zoom = min(zoom + 0.2, 3.0) } label: {
                Image(systemName: "plus")
            }
            .frame(width: 44, height: 44)
            Divider().frame(height: 22)
            Button { zoom = max(zoom - 0.2, 0.4) } label: {
                Image(systemName: "minus")
            }
            .frame(width: 44, height: 44)
            Divider().frame(height: 22)
            Button { zoom = 1.0 } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .frame(width: 44, height: 44)
        }
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(.separator)))
        .padding()
    }
}

/// Draws the connecting lines between nodes.
struct EdgeCanvas: View {
    let edges: [TreeEdge]
    let size: CGSize

    var body: some View {
        Canvas { context, _ in
            for edge in edges {
                var path = Path()
                path.move(to: edge.from)
                path.addLine(to: edge.to)
                context.stroke(path, with: .color(Color.secondary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A single node in the tree — either an operator (glyph + subscript) or a base
/// relation (rounded rectangle with the table name).
struct NodeBubble: View {
    let node: DiagramNode
    /// The size `TreeLayout` reserved. Drawing at exactly that size is what
    /// keeps the picture and the layout from disagreeing — a bubble wider than
    /// its slab is the overlap the calculus scope tree used to show.
    let size: CGSize

    var body: some View {
        if node.isLeaf {
            Text(node.symbol)
                .font(.system(.headline, design: .rounded))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor, lineWidth: 1.5))
        } else {
            VStack(spacing: 2) {
                Text(node.symbol)
                    .font(.system(.title2, design: .serif))
                    .foregroundStyle(Color.accentColor)
                if let detail = node.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: NodeMetrics.detailWidth)
                }
            }
            .frame(width: size.width, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator), lineWidth: 1)
            )
        }
    }
}
