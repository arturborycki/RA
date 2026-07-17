//
//  TreeLayout.swift
//  RelationalAlgebra
//
//  A minimal tidy-tree layout: leaves are placed left-to-right; each internal
//  node is centred over its children. Produces absolute positions plus the
//  parent→child edges for drawing.
//

import Foundation
import CoreGraphics

struct PositionedNode: Identifiable {
    let id: UUID
    let node: RATreeNode
    var center: CGPoint
}

struct TreeEdge: Identifiable {
    let id = UUID()
    var from: CGPoint
    var to: CGPoint
}

struct TreeLayout {
    var nodes: [PositionedNode] = []
    var edges: [TreeEdge] = []
    var size: CGSize = .zero

    /// Horizontal distance between adjacent leaves.
    static let hGap: CGFloat = 150
    /// Vertical distance between tree levels.
    static let vGap: CGFloat = 120
    /// Outer padding around the whole diagram.
    static let padding: CGFloat = 60

    init(root: RATreeNode) {
        var nextLeafX: CGFloat = TreeLayout.padding
        var maxDepth = 0

        // Recursively assign centres. Returns this node's centre x.
        @discardableResult
        func place(_ node: RATreeNode, depth: Int) -> CGFloat {
            maxDepth = max(maxDepth, depth)
            let y = TreeLayout.padding + CGFloat(depth) * TreeLayout.vGap

            let centerX: CGFloat
            if node.children.isEmpty {
                centerX = nextLeafX
                nextLeafX += TreeLayout.hGap
            } else {
                let childXs = node.children.map { place($0, depth: depth + 1) }
                centerX = (childXs.first! + childXs.last!) / 2
            }

            let center = CGPoint(x: centerX, y: y)
            nodes.append(PositionedNode(id: node.id, node: node, center: center))

            for child in node.children {
                if let childPos = nodes.first(where: { $0.id == child.id }) {
                    edges.append(TreeEdge(from: center, to: childPos.center))
                }
            }
            return centerX
        }

        place(root, depth: 0)

        let maxX = nodes.map { $0.center.x }.max() ?? 0
        size = CGSize(width: maxX + TreeLayout.padding,
                      height: TreeLayout.padding * 2 + CGFloat(maxDepth) * TreeLayout.vGap)
    }
}
