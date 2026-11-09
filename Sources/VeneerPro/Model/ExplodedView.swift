import SceneKit
import simd

/// Automatic exploded views (Object tab ▸ Exploded View).
///
/// Parts are pulled apart the way they'd come off in disassembly: for each part the planner finds the
/// directions it can slide out without running into a neighbor (by bounding boxes), peels the free
/// parts off first, and stacks each part just clear of the ones it passes. Groups move as a block,
/// then their own parts spread out inside them. Exploding only adds translations, so it can be blended
/// from 0% to 100% and saved as a pose.
struct ExplodePlan {
    enum Axis: String, CaseIterable, Identifiable {
        case auto = "Auto", x = "X", y = "Y", z = "Z"
        var id: String { rawValue }
        var index: Int? { switch self { case .auto: nil; case .x: 0; case .y: 1; case .z: 2 } }
    }

    enum Order: String, CaseIterable, Identifiable {
        case automatic = "Automatic", sceneList = "Scene List"
        var id: String { rawValue }
    }

    struct Move {
        let node: SCNNode
        /// The node's translation at 100%, in its parent's space.
        let localOffset: SIMD3<Float>
        /// Where the node was when planned, so collapsing lands exactly there (no rounding drift).
        let base: SIMD3<Float>
    }

    var moves: [Move] = []
    /// The fraction currently applied to the nodes.
    var applied: Float = 0

    /// Plans an exploded view of `root`'s visible objects in their current (assembled) positions.
    static func make(root: SCNNode, axis: Axis, nested: Bool, spacing: Float = 1, order: Order = .automatic) -> ExplodePlan {
        var plan = ExplodePlan()
        let settings = Settings(axis: axis, nested: nested, spacing: spacing, order: order, up: upAxis(of: root))
        explode(container: root, root: root, settings: settings, depth: 0, into: &plan)
        return plan
    }

    private struct Settings {
        var axis: Axis
        var nested: Bool
        var spacing: Float
        var order: Order
        var up: Int
    }

    // MARK: Units

    /// The objects at one level that move independently: visible children that contain geometry.
    /// Chains of single wrapper nodes (common in imported files) are skipped.
    private static func units(in container: SCNNode) -> (container: SCNNode, units: [SCNNode]) {
        var container = container
        while true {
            let children = container.childNodes.filter { !$0.isHidden && hasGeometry($0) }
            if children.count == 1, container.geometry == nil {
                container = children[0]
                continue
            }
            return (container, children)
        }
    }

    private static func hasGeometry(_ node: SCNNode) -> Bool {
        if node.geometry != nil { return true }
        return node.childNodes.contains { !$0.isHidden && hasGeometry($0) }
    }

    /// The node's visible geometry bounds in `root`'s space (the node's own geometry only, or the
    /// whole subtree).
    private static func bounds(of node: SCNNode, in root: SCNNode, subtree: Bool = true) -> Box? {
        var box: Box?
        func add(_ n: SCNNode) {
            if let geometry = n.geometry {
                let (lo, hi) = geometry.boundingBox
                for i in 0..<8 {
                    let corner = SCNVector3(i & 1 == 0 ? lo.x : hi.x, i & 2 == 0 ? lo.y : hi.y, i & 4 == 0 ? lo.z : hi.z)
                    let p = SIMD3<Float>(n.convertPosition(corner, to: root))
                    box = box.map { $0.union(p) } ?? Box(lo: p, hi: p)
                }
            }
            guard subtree else { return }
            for child in n.childNodes where !child.isHidden { add(child) }
        }
        add(node)
        return box
    }

    struct Box {
        var lo: SIMD3<Float>
        var hi: SIMD3<Float>
        var center: SIMD3<Float> { (lo + hi) / 2 }
        var size: SIMD3<Float> { hi - lo }
        func union(_ p: SIMD3<Float>) -> Box { Box(lo: simd_min(lo, p), hi: simd_max(hi, p)) }
        func union(_ b: Box) -> Box { Box(lo: simd_min(lo, b.lo), hi: simd_max(hi, b.hi)) }
        func moved(_ v: SIMD3<Float>) -> Box { Box(lo: lo + v, hi: hi + v) }
    }

    // MARK: Planning one level

    private static func explode(container: SCNNode, root: SCNNode, settings: Settings, depth: Int, into plan: inout ExplodePlan) {
        let (container, nodes) = units(in: container)
        guard nodes.count >= 2 || (nodes.count == 1 && container.geometry != nil) else {
            if let only = nodes.first, settings.nested, depth < 6 {
                explode(container: only, root: root, settings: settings, depth: depth + 1, into: &plan)
            }
            return
        }
        var boxes = nodes.compactMap { bounds(of: $0, in: root) }
        guard boxes.count == nodes.count else { return }
        // A container with its own geometry keeps it in place, as an obstacle.
        let fixed = container.geometry != nil ? bounds(of: container, in: root, subtree: false) : nil
        let overrides = nodes.map { $0.explodeDirection.map { $0.index(up: settings.up) } }
        let offsets = solve(boxes: &boxes, fixed: fixed, settings: settings, overrides: overrides)

        for (node, offset) in zip(nodes, offsets) where simd_length(offset) > 0 {
            plan.moves.append(Move(node: node, localOffset: localVector(offset, for: node, root: root), base: node.simdPosition))
        }
        guard settings.nested, depth < 6 else { return }
        for node in nodes {
            explode(container: node, root: root, settings: settings, depth: depth + 1, into: &plan)
        }
    }

    /// The root-space axis that points up in the world (Y, or Z for a Z-up model).
    static func upAxis(of root: SCNNode) -> Int {
        let a = SIMD3<Float>(root.convertPosition(SCNVector3(0, 0, 0), from: nil))
        let b = SIMD3<Float>(root.convertPosition(SCNVector3(0, 1, 0), from: nil))
        let v = simd_abs(b - a)
        return v.x > v.y && v.x > v.z ? 0 : (v.z > v.y ? 2 : 1)
    }

    /// A vector in `root`'s space as a translation in `node`'s parent space.
    private static func localVector(_ v: SIMD3<Float>, for node: SCNNode, root: SCNNode) -> SIMD3<Float> {
        guard let parent = node.parent else { return v }
        let a = SIMD3<Float>(parent.convertPosition(SCNVector3(0, 0, 0), from: root))
        let b = SIMD3<Float>(parent.convertPosition(SCNVector3(v.x, v.y, v.z), from: root))
        return b - a
    }

    /// The offset (in root space) for each box at 100%.
    private static func solve(boxes: inout [Box], fixed: Box?, settings: Settings, overrides: [Int?]) -> [SIMD3<Float>] {
        let axis = settings.axis, up = settings.up, spacing = settings.spacing
        let n = boxes.count
        var all = boxes.reduce(boxes[0]) { $0.union($1) }
        if let fixed { all = all.union(fixed) }
        let center = all.center
        let diagonal = max(simd_length(all.size), 1e-4)
        // Gaps scale with the part that moves (a screw gets a small gap, a housing a bigger one).
        func gap(_ box: Box, _ k: Int) -> Float {
            min(max(box.size[k] * 0.3, diagonal * 0.012), diagonal * 0.05) * spacing
        }
        // Stacks come apart vertically unless a direction is chosen.
        let main = axis.index ?? up

        // Direction d = axis * 2 + (0 for +, 1 for −). blockers[i][d]: parts in i's way along d.
        let tolerance: Float = 0.02
        func lateral(_ a: Box, _ b: Box, _ axis: Int) -> Bool {
            for k in 0..<3 where k != axis {
                let shrink = min(a.size[k], b.size[k]) * tolerance
                if a.hi[k] - shrink <= b.lo[k] || b.hi[k] - shrink <= a.lo[k] { return false }
            }
            return true
        }
        func blocks(_ j: Box, _ i: Box, _ d: Int) -> Bool {
            let k = d / 2, eps = max(i.size[k], j.size[k]) * tolerance
            guard lateral(i, j, k) else { return false }
            return d % 2 == 0 ? j.hi[k] > i.hi[k] + eps : j.lo[k] < i.lo[k] - eps
        }
        var blockedBy = Array(repeating: Array(repeating: Set<Int>(), count: 6), count: n)
        var fixedBlocks = Array(repeating: Array(repeating: false, count: 6), count: n)
        for i in 0..<n {
            for d in 0..<6 {
                for j in 0..<n where j != i && blocks(boxes[j], boxes[i], d) { blockedBy[i][d].insert(j) }
                if let fixed, blocks(fixed, boxes[i], d) { fixedBlocks[i][d] = true }
            }
        }

        // Peel: repeatedly take the part that's free to leave in the best direction.
        func unit(_ d: Int) -> SIMD3<Float> {
            var v = SIMD3<Float>(repeating: 0)
            v[d / 2] = d % 2 == 0 ? 1 : -1
            return v
        }
        /// How far part i must travel along d to clear the parts and fixed geometry it overlaps.
        func travel(_ i: Int, _ d: Int, among others: Set<Int>) -> Float {
            let k = d / 2, box = boxes[i]
            var t: Float = 0
            var obstacles = others.filter { $0 != i }.map { boxes[$0] }
            if let fixed { obstacles.append(fixed) }
            for o in obstacles where lateral(box, o, k) {
                t = max(t, d % 2 == 0 ? o.hi[k] - box.lo[k] : box.hi[k] - o.lo[k])
            }
            return max(t, 0)
        }
        // Measured once against every part (re-measuring as parts peel off is cubic for big assemblies).
        let everyone = Set(0..<n)
        let travels = (0..<n).map { i in (0..<6).map { d in travel(i, d, among: everyone) } }
        // A part's chosen Explode Direction wins; otherwise its natural way out.
        let natural = preferredDirections(boxes, main: main, center: center, diagonal: diagonal)
        let preferred = (0..<n).map { overrides[$0] ?? natural[$0] }
        /// Directions part i may leave in with `others` still in place.
        func allowed(_ i: Int, among others: Set<Int>) -> [Int] {
            if let forced = overrides[i] { return [forced] }
            return (0..<6).filter { !fixedBlocks[i][$0] && blockedBy[i][$0].isDisjoint(with: others) }
        }
        func score(_ i: Int, _ d: Int, among others: Set<Int>) -> Float {
            var away = boxes[i].center - center
            if simd_length(away) < 1e-6 { away = unit(main * 2) }
            // Each part's natural way out (stacked: along the stack; side by side: apart; overhanging:
            // the way it sticks out), then the short way out, then away from the middle.
            var s = simd_dot(simd_normalize(away), unit(d)) * 0.3 - travels[i][d] / diagonal
            if d == preferred[i] { s += 2 }
            if axis != .auto, d / 2 == main { s += 10 }
            return s
        }
        var remaining = Set(0..<n)
        var order: [(part: Int, dir: Int)] = []   // outermost first
        let keep = fixed == nil ? 1 : 0           // the core part that stays put
        if settings.order == .sceneList {
            // The Scene list's order: the top row comes off first; the last row stays (the core).
            for i in 0..<(n - keep) {
                remaining.remove(i)
                let options = allowed(i, among: remaining)
                let d = options.max { score(i, $0, among: remaining) < score(i, $1, among: remaining) } ?? preferred[i]
                order.append((i, d))
            }
        } else {
            while remaining.count > keep {
                var best: (part: Int, dir: Int, score: Float)?
                for i in remaining {
                    for d in allowed(i, among: remaining.subtracting([i])) {
                        let s = score(i, d, among: remaining) + (overrides[i] != nil ? 1 : 0)
                        if best == nil || s > best!.score { best = (i, d, s) }
                    }
                }
                if best == nil {
                    // Interlocked: pull out the least-blocked part, away from the middle.
                    for i in remaining {
                        for d in 0..<6 {
                            let s = score(i, d, among: remaining) - Float(blockedBy[i][d].intersection(remaining).count) - (fixedBlocks[i][d] ? 5 : 0)
                            if best == nil || s > best!.score { best = (i, d, s) }
                        }
                    }
                }
                guard let pick = best else { break }
                order.append((pick.part, pick.dir))
                remaining.remove(pick.part)
            }
        }
        // The last part left (the core) stays put.

        // Place from the inside out: each part clears everything already placed in its path.
        var placed: [Box] = remaining.map { boxes[$0] }
        if let fixed { placed.append(fixed) }
        var offsets = Array(repeating: SIMD3<Float>(repeating: 0), count: n)
        for (i, d) in order.reversed() {
            let k = d / 2, positive = d % 2 == 0
            let box = boxes[i]
            var shift: Float = 0
            let g = gap(box, k)
            for other in placed where lateral(box, other, k) {
                if positive, other.hi[k] > box.lo[k] { shift = max(shift, other.hi[k] + g - box.lo[k]) }
                if !positive, other.lo[k] < box.hi[k] { shift = min(shift, other.lo[k] - g - box.hi[k]) }
            }
            if shift == 0 { shift = positive ? g : -g }
            var offset = SIMD3<Float>(repeating: 0)
            offset[k] = shift
            offsets[i] = offset
            placed.append(box.moved(offset))
        }
        return offsets
    }

    /// Each part's natural way out, as a direction index (axis * 2, + 1 for negative):
    /// - side by side with a neighbor at the same height (two halves of a shell): apart from it;
    /// - stacked on a neighbor (mostly directly above or below it): along the stack, away from it;
    /// - overhanging what it touches (a cantilevered head): outward, the way it sticks out.
    static func preferredDirections(_ boxes: [Box], main m: Int, center: SIMD3<Float>, diagonal: Float) -> [Int] {
        let n = boxes.count
        let eps = diagonal * 0.01
        let lateralAxes = [0, 1, 2].filter { $0 != m }
        func touches(_ a: Box, _ b: Box) -> Bool {
            (0..<3).allSatisfy { a.lo[$0] - eps <= b.hi[$0] && b.lo[$0] - eps <= a.hi[$0] }
        }
        func overlap(_ a: Box, _ b: Box, _ k: Int) -> Float { max(0, min(a.hi[k], b.hi[k]) - max(a.lo[k], b.lo[k])) }
        func footprint(_ a: Box) -> Float { lateralAxes.reduce(1) { $0 * max(a.size[$1], eps) } }
        func footprintOverlap(_ a: Box, _ b: Box) -> Float { lateralAxes.reduce(1) { $0 * overlap(a, b, $1) } }
        func direction(_ v: SIMD3<Float>, axes: [Int]) -> Int {
            let k = axes.max { abs(v[$0]) < abs(v[$1]) } ?? m
            return k * 2 + (v[k] >= 0 ? 0 : 1)
        }

        return (0..<n).map { i in
            let a = boxes[i]
            let neighbors = (0..<n).filter { $0 != i && touches(a, boxes[$0]) }
            var apart = SIMD3<Float>(repeating: 0)
            var stackedOn: [Int] = []
            for j in neighbors {
                let b = boxes[j]
                let sameHeight = overlap(a, b, m) / max(min(a.size[m], b.size[m]), eps)
                let shared = footprintOverlap(a, b) / min(footprint(a), footprint(b))
                if sameHeight >= 0.5 && shared < 0.4 {
                    var v = a.center - b.center
                    v[m] = 0
                    apart += v
                } else if footprintOverlap(a, b) / footprint(a) >= 0.5 {
                    stackedOn.append(j)
                }
            }
            if simd_length(apart) > eps * 0.1 { return direction(apart, axes: lateralAxes) }
            if !stackedOn.isEmpty {
                let below = stackedOn.map { boxes[$0].center[m] }.reduce(0, +) / Float(stackedOn.count)
                let side = a.center[m] - below
                let sign: Float = abs(side) > eps * 0.1 ? side : a.center[m] - center[m]
                return m * 2 + (sign >= 0 ? 0 : 1)
            }
            if !neighbors.isEmpty {
                let anchor = neighbors.map { boxes[$0].center }.reduce(SIMD3<Float>(repeating: 0), +) / Float(neighbors.count)
                return direction(a.center - anchor, axes: lateralAxes)
            }
            return direction(a.center - center, axes: [0, 1, 2])
        }
    }

    // MARK: Applying

    /// Moves the nodes from the currently applied fraction to `t`, keeping any edits made in between.
    mutating func apply(_ t: Float, root: SCNNode) {
        let delta = t - applied
        guard delta != 0 else { return }
        for move in moves where move.node.isDescendant(of: root) {
            var p = move.node.simdPosition + move.localOffset * delta
            if t == 0, simd_length(p - move.base) < 1e-5 { p = move.base }
            move.node.simdPosition = p
        }
        applied = t
    }
}

/// A model's exploded-view settings and its current plan.
struct ExplodeState {
    var amount: Float = 0
    var axis: ExplodePlan.Axis = .auto
    var nested = true
    var spacing: Float = 1
    var order: ExplodePlan.Order = .automatic
    var plan: ExplodePlan?

    func makePlan(_ root: SCNNode) -> ExplodePlan {
        ExplodePlan.make(root: root, axis: axis, nested: nested, spacing: spacing, order: order)
    }
}

extension AppModel {
    // MARK: Exploded view

    /// Sets how far the selected model is exploded (0…1). Slider drags coalesce into one undo step.
    func setExplode(_ amount: Float) {
        guard let document = selectedDocument else { return }
        let amount = min(max(amount, 0), 1)
        if document.explode.plan == nil || document.explode.amount == 0 && document.explode.plan?.applied == 0 {
            // Plan from the arrangement as it is now (it may have changed since the last plan).
            document.explode.plan = document.explode.makePlan(document.root)
        }
        beginExplodeEdit(document, name: amount == 0 ? "Collapse" : "Explode")
        document.explode.plan?.apply(amount, root: document.root)
        document.explode.amount = amount
        document.sceneChanged()
    }

    /// Re-plans with new settings, keeping the current amount.
    func updateExplodeSettings(axis: ExplodePlan.Axis? = nil, nested: Bool? = nil, spacing: Float? = nil,
                               order: ExplodePlan.Order? = nil) {
        guard let document = selectedDocument else { return }
        let amount = document.explode.amount
        beginExplodeEdit(document, name: "Exploded View Settings")
        document.explode.plan?.apply(0, root: document.root)
        if let axis { document.explode.axis = axis }
        if let nested { document.explode.nested = nested }
        if let spacing { document.explode.spacing = spacing }
        if let order { document.explode.order = order }
        var plan = document.explode.makePlan(document.root)
        plan.apply(amount, root: document.root)
        document.explode.plan = plan
        document.sceneChanged()
    }

    /// Runs `body` (a hierarchy edit) with the model collapsed, then explodes it again with a fresh
    /// plan, so reordering or regrouping updates the exploded view instead of scrambling it.
    func withCollapsedExplode(_ document: ModelDocument, _ body: () -> Void) {
        let amount = document.explode.amount
        guard amount > 0, document.explode.plan != nil else { body(); return }
        document.explode.plan?.apply(0, root: document.root)
        body()
        var plan = document.explode.makePlan(document.root)
        plan.apply(amount, root: document.root)
        document.explode.plan = plan
        document.sceneChanged()
    }

    /// Pins (or with nil, frees) the direction an object comes out in exploded views.
    func setExplodeDirection(_ node: SCNNode, _ direction: ExplodeDirection?) {
        guard let document = selectedDocument else { return }
        history.flush()
        let old = node.explodeDirection
        let apply: (ExplodeDirection?) -> Void = { [weak self, weak document] value in
            guard let self, let document else { return }
            self.withCollapsedExplode(document) { node.explodeDirection = value }
            document.sceneChanged()
        }
        apply(direction)
        noteProjectEdit()
        history.record("Explode Direction", undo: { apply(old) }, redo: { apply(direction) })
    }

    /// Saves the current exploded arrangement as a pose named "Exploded".
    func saveExplodedPose() {
        guard let document = selectedDocument else { return }
        var name = "Exploded", n = 2
        while document.poses.contains(where: { $0.name == name }) { name = "Exploded \(n)"; n += 1 }
        savePose()
        if let pose = document.poses.last { renamePose(pose, to: name) }
    }

    /// Forgets the plan without moving anything (after a pose or other arrangement replaces it).
    func resetExplodeState(_ document: ModelDocument) {
        document.explode.amount = 0
        document.explode.plan = nil
    }

    private func beginExplodeEdit(_ document: ModelDocument, name: String) {
        let key = "explode-\(ObjectIdentifier(document))"
        let before = document.currentPoseStates, beforeState = document.explode
        history.beginGroup(key) { [weak document] in
            guard let document else { return nil }
            let after = document.currentPoseStates, afterState = document.explode
            return EditHistory.Step(name: name, undo: { [weak document] in
                document?.applyPoseStates(before)
                document?.explode = beforeState
            }, redo: { [weak document] in
                document?.applyPoseStates(after)
                document?.explode = afterState
            })
        }
        noteProjectEdit()
    }
}

/// A direction an object is pinned to in exploded views (right-click ▸ Explode Direction).
enum ExplodeDirection: String, Codable, CaseIterable, Identifiable {
    case up, down, left, right, front, back
    var id: String { rawValue }
    var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The planner's direction index (axis * 2, + 1 for negative) for a model whose up axis is `up`.
    func index(up: Int) -> Int {
        // Right and front relative to the up axis: Y-up → +X, +Z; Z-up → +X, −Y; X-up → +Y, +Z.
        let (right, front): ((Int, Bool), (Int, Bool)) = switch up {
        case 2: ((0, true), (1, false))
        case 0: ((1, true), (2, true))
        default: ((0, true), (2, true))
        }
        func d(_ axis: (Int, Bool), _ flip: Bool) -> Int { axis.0 * 2 + (axis.1 != flip ? 0 : 1) }
        switch self {
        case .up: return up * 2
        case .down: return up * 2 + 1
        case .right: return d(right, false)
        case .left: return d(right, true)
        case .front: return d(front, false)
        case .back: return d(front, true)
        }
    }
}

extension SCNNode {
    private static let explodeKey = "VeneerExplodeDirection"

    /// The direction this object is pinned to in exploded views, or nil for automatic.
    var explodeDirection: ExplodeDirection? {
        get { (value(forKey: Self.explodeKey) as? String).flatMap(ExplodeDirection.init(rawValue:)) }
        set { setValue(newValue?.rawValue, forKey: Self.explodeKey) }
    }
}
