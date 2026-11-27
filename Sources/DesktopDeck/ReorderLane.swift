import SwiftUI

/// A single row or column of equal-sized items. Keep the lifted view alive so
/// live previews stay attached while the surrounding cells slide into place.
struct ReorderLane<Cell: View>: View {
    let axis: Axis
    let extent: CGFloat
    let ids: [UUID]
    let tint: Color
    let reorder: ([UUID]) -> Void
    @ViewBuilder let cell: (UUID) -> Cell

    private struct Lift {
        let source: Int
        let grabOffset: CGFloat
        var pointer: CGPoint
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lift: Lift?
    @GestureState private var dragging = false
    @State private var scroll = ScrollPosition()
    @State private var scrollOffset: CGFloat = 0
    @Namespace private var viewport

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let destination = lift.map { self.destination(for: $0, at: scrollOffset) }
            ScrollView(axis == .horizontal ? .horizontal : .vertical) {
                ZStack(alignment: .topLeading) {
                    if let destination {
                        Rectangle().fill(tint.opacity(0.10))
                            .overlay(Rectangle().strokeBorder(tint.opacity(0.55), lineWidth: 1))
                            .frame(width: cellWidth(size), height: cellHeight(size))
                            .offset(offset(CGFloat(destination) * extent))
                            .animation(motion, value: destination)
                            .accessibilityHidden(true)
                    }
                    ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                        let activeLift = lift.flatMap { $0.source == index ? $0 : nil }
                        let lifted = activeLift != nil
                        let slot = slot(for: index, destination: destination)
                        let origin = activeLift.map { coordinate($0.pointer) + scrollOffset - $0.grabOffset }
                            ?? CGFloat(slot) * extent
                        cell(id)
                            .frame(width: cellWidth(size), height: cellHeight(size))
                            .overlay {
                                if lifted { Rectangle().strokeBorder(tint, lineWidth: 2).allowsHitTesting(false) }
                            }
                            .shadow(color: lifted ? .black.opacity(0.65) : .clear, radius: 8)
                            .scaleEffect(lifted ? 0.94 : 1)
                            .animation(motion, value: lifted)
                            .offset(offset(origin))
                            .zIndex(lifted ? 1 : 0)
                            .animation(lifted ? nil : motion, value: slot)
                            .animation(lifted ? nil : motion, value: lifted)
                    }
                }
                .frame(width: axis == .horizontal ? contentLength : size.width,
                       height: axis == .vertical ? contentLength : size.height, alignment: .topLeading)
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture(in: size))
            }
            .coordinateSpace(name: viewport)
            .scrollIndicators(.never)
            .scrollPosition($scroll)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                coordinate(geometry.contentOffset)
            } action: { _, value in scrollOffset = value }
            .task(id: edgeDirection(in: size)) { await scrollWhileDragging(in: size) }
        }
        .onChange(of: dragging) { _, active in if !active { lift = nil } }
        .onChange(of: ids) { _, _ in lift = nil }
    }

    private var contentLength: CGFloat { CGFloat(ids.count) * extent }
    private var motion: Animation? { reduceMotion ? nil : .smooth(duration: 0.19) }

    private func cellWidth(_ size: CGSize) -> CGFloat { axis == .horizontal ? extent : size.width }
    private func cellHeight(_ size: CGSize) -> CGFloat { axis == .vertical ? extent : size.height }
    private func coordinate(_ point: CGPoint) -> CGFloat { axis == .horizontal ? point.x : point.y }
    private func length(_ size: CGSize) -> CGFloat { axis == .horizontal ? size.width : size.height }
    private func offset(_ value: CGFloat) -> CGSize {
        axis == .horizontal ? CGSize(width: value, height: 0) : CGSize(width: 0, height: value)
    }

    private func destination(for lift: Lift, at scrollOffset: CGFloat) -> Int {
        let origin = coordinate(lift.pointer) + scrollOffset - lift.grabOffset
        return min(ids.count - 1, max(0, Int((origin / extent).rounded())))
    }

    private func slot(for index: Int, destination: Int?) -> Int {
        guard let source = lift?.source, let destination, index != source else { return index }
        if source < index && index <= destination { return index - 1 }
        if destination <= index && index < source { return index + 1 }
        return index
    }

    private func reorderGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(viewport))
            .updating($dragging) { _, active, _ in active = true }
            .onChanged { drag in
                if lift != nil {
                    lift?.pointer = drag.location
                } else if ids.count > 1 {
                    let start = coordinate(drag.startLocation) + scrollOffset
                    guard start >= 0, start < contentLength else { return }
                    let index = Int(start / extent)
                    lift = Lift(source: index, grabOffset: start - CGFloat(index) * extent, pointer: drag.location)
                }
            }
            .onEnded { drag in
                guard var lifted = lift else { return }
                lift = nil
                guard CGRect(origin: .zero, size: size).contains(drag.location) else { return }
                lifted.pointer = drag.location
                let target = destination(for: lifted, at: scrollOffset)
                guard lifted.source != target, ids.indices.contains(lifted.source) else { return }
                var order = ids
                let id = order.remove(at: lifted.source)
                order.insert(id, at: target)
                reorder(order)
            }
    }

    private func edgeDirection(in size: CGSize) -> CGFloat {
        guard let lift, CGRect(origin: .zero, size: size).contains(lift.pointer), contentLength > length(size) else { return 0 }
        let edge = min(34, length(size) / 4)
        let point = coordinate(lift.pointer)
        if point < edge { return -1 }
        if point > length(size) - edge { return 1 }
        return 0
    }

    private func scrollWhileDragging(in size: CGSize) async {
        let direction = edgeDirection(in: size)
        guard direction != 0 else { return }
        var position = scrollOffset
        while !Task.isCancelled && lift != nil {
            let next = min(contentLength - length(size), max(0, position + direction * 6))
            guard next != position else { return }
            position = next
            if axis == .horizontal { scroll.scrollTo(x: position) }
            else { scroll.scrollTo(y: position) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}
