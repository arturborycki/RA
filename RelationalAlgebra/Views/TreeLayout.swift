//
//  TreeLayout.swift
//  RelationalAlgebra
//
//  A tidy-tree layout: every subtree is given a horizontal slab at least as
//  wide as it needs, and each node is centred over its children.
//
//  Node *size* is the whole difficulty. The algebra's nodes are single glyphs —
//  σ, π, ⋈ — and a fixed column width serves them. The calculus scope tree
//  reuses this view for nodes labelled `Employee(e, n, s, …)` or a whole
//  comparison, which are several times wider, so a fixed width overlapped them.
//  Each node is therefore measured with the same fonts the bubble draws with,
//  and the measurement is handed back so the bubble is drawn at exactly the
//  size that was reserved for it.
//

import UIKit
import CoreGraphics

struct PositionedNode: Identifiable {
    let id: UUID
    let node: DiagramNode
    var center: CGPoint
    /// The size reserved for this node — what `NodeBubble` is drawn at, so the
    /// picture and the layout cannot disagree.
    var size: CGSize
}

struct TreeEdge: Identifiable {
    let id = UUID()
    var from: CGPoint
    var to: CGPoint
}

// MARK: - Measurement

/// The size each node needs, measured with the fonts `NodeBubble` draws with.
enum NodeMetrics {
    /// Matches `NodeBubble`'s padding.
    static let leafPadding = CGSize(width: 32, height: 20)
    static let branchPadding = CGSize(width: 24, height: 16)
    /// The detail line wraps rather than widening past this.
    static let detailWidth: CGFloat = 132
    /// A leaf wraps rather than widening past this. The algebra's leaves are
    /// table names and never reach it; a domain atom like
    /// `Lineitem(o, p, s, q, …)` would otherwise make one node wider than the
    /// screen and the whole tree unreadable.
    static let leafWidth: CGFloat = 200

    static func size(of node: DiagramNode) -> CGSize {
        if node.isLeaf {
            let leafFont = font(.headline, design: .rounded)
            let text = measure(node.symbol, font: leafFont, maxWidth: leafWidth)
            let twoLines = ceil(leafFont.lineHeight * 2)
            return CGSize(width: min(text.width, leafWidth) + leafPadding.width,
                          height: min(text.height, twoLines) + leafPadding.height)
        }

        let symbol = measure(node.symbol, font: font(.title2, design: .serif))
        var width = symbol.width
        var height = symbol.height

        if let detail = node.detail, !detail.isEmpty {
            let detailFont = font(.caption2, design: .monospaced)
            // Wrapped to at most two lines, exactly as the bubble does.
            let wrapped = measure(detail, font: detailFont, maxWidth: detailWidth)
            let twoLines = ceil(detailFont.lineHeight * 2)
            width = max(width, min(wrapped.width, detailWidth))
            height += 2 + min(wrapped.height, twoLines)
        }

        return CGSize(width: width + branchPadding.width,
                      height: height + branchPadding.height)
    }

    private static func font(_ style: UIFont.TextStyle,
                             design: UIFontDescriptor.SystemDesign) -> UIFont {
        let base = UIFont.preferredFont(forTextStyle: style)
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static func measure(_ text: String, font: UIFont,
                                maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGSize {
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil)
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}

// MARK: - Layout

struct TreeLayout {
    var nodes: [PositionedNode] = []
    var edges: [TreeEdge] = []
    var size: CGSize = .zero

    /// Clear space between two adjacent subtrees.
    static let hGap: CGFloat = 28
    /// Clear space between one level and the next.
    static let vGap: CGFloat = 54
    /// Outer padding around the whole diagram.
    static let padding: CGFloat = 40
    /// How far a connecting line stops short of the box it points at.
    static let edgeInset: CGFloat = 3

    init(root: DiagramNode) {
        // Pass 1: how wide each subtree needs to be, and how tall each level is.
        var subtreeWidth: [UUID: CGFloat] = [:]
        var nodeSize: [UUID: CGSize] = [:]
        var levelHeight: [CGFloat] = []

        @discardableResult
        func measure(_ node: DiagramNode, depth: Int) -> CGFloat {
            let own = NodeMetrics.size(of: node)
            nodeSize[node.id] = own

            while levelHeight.count <= depth { levelHeight.append(0) }
            levelHeight[depth] = max(levelHeight[depth], own.height)

            guard !node.children.isEmpty else {
                subtreeWidth[node.id] = own.width
                return own.width
            }
            let childrenWidth = node.children.reduce(CGFloat(0)) { total, child in
                total + measure(child, depth: depth + 1)
            } + TreeLayout.hGap * CGFloat(node.children.count - 1)

            // A node wider than its children still gets the room it needs.
            let width = max(own.width, childrenWidth)
            subtreeWidth[node.id] = width
            return width
        }
        measure(root, depth: 0)

        // Each level starts below the tallest node of the level above, so a
        // two-line detail cannot collide with the row beneath it.
        var levelY: [CGFloat] = []
        var y = TreeLayout.padding
        for height in levelHeight {
            levelY.append(y + height / 2)
            y += height + TreeLayout.vGap
        }
        let contentHeight = y - TreeLayout.vGap + TreeLayout.padding

        // Pass 2: place each subtree inside the slab reserved for it.
        @discardableResult
        func place(_ node: DiagramNode, left: CGFloat, depth: Int) -> CGPoint {
            let own = nodeSize[node.id] ?? .zero
            let slab = subtreeWidth[node.id] ?? own.width
            let centerX: CGFloat
            var childCenters: [CGPoint] = []

            if node.children.isEmpty {
                centerX = left + slab / 2
            } else {
                let childrenWidth = node.children.reduce(CGFloat(0)) {
                    $0 + (subtreeWidth[$1.id] ?? 0)
                } + TreeLayout.hGap * CGFloat(node.children.count - 1)

                // Children sit centred within this subtree's slab.
                var x = left + (slab - childrenWidth) / 2
                for child in node.children {
                    childCenters.append(place(child, left: x, depth: depth + 1))
                    x += (subtreeWidth[child.id] ?? 0) + TreeLayout.hGap
                }
                centerX = ((childCenters.first?.x ?? left) + (childCenters.last?.x ?? left)) / 2
            }

            let center = CGPoint(x: centerX, y: levelY[depth])
            nodes.append(PositionedNode(id: node.id, node: node, center: center, size: own))

            // Edges stop at the boxes rather than running through them.
            for (child, childCenter) in zip(node.children, childCenters) {
                let childSize = nodeSize[child.id] ?? .zero
                edges.append(TreeEdge(
                    from: TreeLayout.boundary(of: center, size: own, toward: childCenter),
                    to: TreeLayout.boundary(of: childCenter, size: childSize, toward: center)))
            }
            return center
        }
        place(root, left: TreeLayout.padding, depth: 0)

        let maxX = nodes.map { $0.center.x + $0.size.width / 2 }.max() ?? 0
        size = CGSize(width: maxX + TreeLayout.padding, height: contentHeight)
    }

    /// Where a line from `center` towards `target` leaves this node's box, plus
    /// a small inset so it stops just short of the border.
    static func boundary(of center: CGPoint, size: CGSize, toward target: CGPoint) -> CGPoint {
        let dx = target.x - center.x
        let dy = target.y - center.y
        guard dx != 0 || dy != 0 else { return center }

        let tx = dx == 0 ? CGFloat.greatestFiniteMagnitude : (size.width / 2) / abs(dx)
        let ty = dy == 0 ? CGFloat.greatestFiniteMagnitude : (size.height / 2) / abs(dy)
        let t = min(tx, ty)

        let length = (dx * dx + dy * dy).squareRoot()
        let inset = length > 0 ? edgeInset / length : 0
        let scale = min(t + inset, 1)
        return CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
    }
}
