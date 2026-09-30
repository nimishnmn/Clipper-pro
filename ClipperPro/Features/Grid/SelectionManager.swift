import Foundation
import SwiftUI

/// Manages multi-clip selection with click-drag rubber-band support.
@MainActor
final class SelectionManager: ObservableObject {
    @Published var selectedIDs: Set<UUID> = []
    @Published var isDragging = false
    @Published var dragRect: CGRect = .zero
    
    var onSelectionChanged: ((Set<UUID>) -> Void)?
    
    private var anchorPoint: CGPoint = .zero
    private var cellFrames: [UUID: CGRect] = [:]
    
    // MARK: - Basic Selection
    
    func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
        onSelectionChanged?(selectedIDs)
    }
    
    func select(_ id: UUID) {
        selectedIDs.insert(id)
        onSelectionChanged?(selectedIDs)
    }
    
    func deselect(_ id: UUID) {
        selectedIDs.remove(id)
        onSelectionChanged?(selectedIDs)
    }
    
    func selectAll(_ ids: [UUID]) {
        selectedIDs = Set(ids)
        onSelectionChanged?(selectedIDs)
    }
    
    func clear() {
        selectedIDs.removeAll()
        onSelectionChanged?(selectedIDs)
    }
    
    func isSelected(_ id: UUID) -> Bool {
        selectedIDs.contains(id)
    }
    
    // MARK: - Rubber-Band Drag Selection
    
    func registerCellFrame(_ frame: CGRect, for id: UUID) {
        cellFrames[id] = frame
    }
    
    func dragBegan(at point: CGPoint) {
        anchorPoint = point
        dragRect = CGRect(origin: point, size: .zero)
        isDragging = true
    }
    
    func dragChanged(to point: CGPoint, additive: Bool = false) {
        let origin = CGPoint(
            x: min(anchorPoint.x, point.x),
            y: min(anchorPoint.y, point.y)
        )
        let size = CGSize(
            width:  abs(point.x - anchorPoint.x),
            height: abs(point.y - anchorPoint.y)
        )
        dragRect = CGRect(origin: origin, size: size)
        
        // Update selection based on intersection
        let intersecting = cellFrames.filter { $0.value.intersects(dragRect) }.map(\.key)
        if additive {
            intersecting.forEach { selectedIDs.insert($0) }
        } else {
            selectedIDs = Set(intersecting)
        }
        onSelectionChanged?(selectedIDs)
    }
    
    func dragEnded() {
        isDragging = false
        dragRect = .zero
    }
}
