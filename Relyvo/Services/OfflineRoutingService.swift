import Foundation
import CoreLocation

/// Represents a state in the A* search
private struct SearchState: Hashable {
    let nodeID: Int64
    let previousEdgeID: Int64?
    
    init(nodeID: Int64, previousEdgeID: Int64? = nil) {
        self.nodeID = nodeID
        self.previousEdgeID = previousEdgeID
    }
}

/// A node in the priority queue
private struct PQNode: Comparable {
    let state: SearchState
    let fScore: Double
    let gScore: Double
    
    static func < (lhs: PQNode, rhs: PQNode) -> Bool {
        if lhs.fScore == rhs.fScore {
            // Tie-breaker: favor higher gScore (closer to destination)
            return lhs.gScore > rhs.gScore
        }
        return lhs.fScore < rhs.fScore
    }
    
    static func == (lhs: PQNode, rhs: PQNode) -> Bool {
        return lhs.state == rhs.state
    }
}

/// Binary Min-Heap Priority Queue
private struct PriorityQueue<T: Comparable> {
    private var heap = [T]()
    
    var isEmpty: Bool { heap.isEmpty }
    var count: Int { heap.count }
    
    mutating func push(_ element: T) {
        heap.append(element)
        siftUp(from: heap.count - 1)
    }
    
    mutating func pop() -> T? {
        if heap.isEmpty { return nil }
        if heap.count == 1 { return heap.removeLast() }
        let root = heap[0]
        heap[0] = heap.removeLast()
        siftDown(from: 0)
        return root
    }
    
    private mutating func siftUp(from index: Int) {
        var child = index
        var parent = (child - 1) / 2
        while child > 0 && heap[child] < heap[parent] {
            heap.swapAt(child, parent)
            child = parent
            parent = (child - 1) / 2
        }
    }
    
    private mutating func siftDown(from index: Int) {
        var parent = index
        while true {
            let leftChild = 2 * parent + 1
            let rightChild = 2 * parent + 2
            var candidate = parent
            if leftChild < heap.count && heap[leftChild] < heap[candidate] {
                candidate = leftChild
            }
            if rightChild < heap.count && heap[rightChild] < heap[candidate] {
                candidate = rightChild
            }
            if candidate == parent { return }
            heap.swapAt(parent, candidate)
            parent = candidate
        }
    }
}

/// Core offline routing engine.
final class OfflineRoutingService: Sendable {
    private let database: RoutingDatabase
    
    init(database: RoutingDatabase) {
        self.database = database
    }
    
    /// Calculate route from origin to destination entirely offline.
    func calculateRoute(from origin: CLLocationCoordinate2D, to destination: CLLocationCoordinate2D) async throws -> Route {
        
        // Phase 10: Region Validation
        let region = try database.region()
        guard region.contains(origin) && region.contains(destination) else {
            throw RoutingError.regionUnavailable
        }
        
        // Phase 9: Destination Handling (Node Snapping)
        let startNode = try database.nearestNode(to: origin)
        let endNode = try database.nearestNode(to: destination)
        
        if startNode.id == endNode.id {
            throw RoutingError.noRouteFound
        }
        
        // A* State Management
        var openQueue = PriorityQueue<PQNode>()
        var gScores = [SearchState: Double]()
        var cameFromNode = [SearchState: SearchState]()
        var cameFromEdge = [SearchState: Int64]()
        
        // Initial State
        let startState = SearchState(nodeID: startNode.id, previousEdgeID: nil)
        gScores[startState] = 0.0
        openQueue.push(PQNode(state: startState, fScore: heuristic(from: startNode, to: endNode), gScore: 0.0))
        
        var reachedEndState: SearchState?
        
        // A* Loop
        while let current = openQueue.pop() {
            // Check cancellation periodically
            try Task.checkCancellation()
            
            let currentState = current.state
            
            // Reached destination?
            if currentState.nodeID == endNode.id {
                reachedEndState = currentState
                break
            }
            
            // Skip if we already found a strictly better path to this exact state
            if let bestG = gScores[currentState], bestG < current.gScore {
                continue
            }
            
            // Expand neighbors
            let outgoingEdges = try database.outgoingEdges(from: currentState.nodeID)
            
            // Load restrictions if we arrived via an edge
            var restrictions = [RoutingRestriction]()
            if let prevEdgeID = currentState.previousEdgeID {
                restrictions = try database.restrictedTransitions(from: prevEdgeID)
            }
            
            for edge in outgoingEdges {
                let candidateEdgeID = edge.edgeID
                
                // Phase 8: Turn Restrictions
                var isRestricted = false
                var hasOnlyTurn = false
                var allowedOnlyTurnEdge: Int64? = nil
                
                for r in restrictions {
                    if r.type == 0 { // NO_TURN
                        if r.toEdgeId == candidateEdgeID {
                            isRestricted = true
                            break
                        }
                    } else if r.type == 1 { // ONLY_TURN
                        hasOnlyTurn = true
                        if r.toEdgeId == candidateEdgeID {
                            allowedOnlyTurnEdge = candidateEdgeID
                        }
                    }
                }
                
                if isRestricted { continue }
                if hasOnlyTurn && allowedOnlyTurnEdge != candidateEdgeID {
                    continue
                }
                
                // tentative_gScore = gScore + length
                let tentativeG = current.gScore + edge.lengthMeters
                let nextState = SearchState(nodeID: edge.destinationNodeID, previousEdgeID: candidateEdgeID)
                
                let existingG = gScores[nextState] ?? Double.greatestFiniteMagnitude
                
                if tentativeG < existingG {
                    cameFromNode[nextState] = currentState
                    cameFromEdge[nextState] = candidateEdgeID
                    gScores[nextState] = tentativeG
                    
                    let nextNode = try database.node(id: edge.destinationNodeID)
                    let h = heuristic(from: nextNode, to: endNode)
                    let f = tentativeG + h
                    
                    openQueue.push(PQNode(state: nextState, fScore: f, gScore: tentativeG))
                }
            }
        }
        
        // Phase 11: Route Reconstruction
        guard let finalState = reachedEndState else {
            throw RoutingError.noRouteFound
        }
        
        var pathNodes = [Int64]()
        var pathEdges = [Int64]()
        
        var cur: SearchState? = finalState
        while let s = cur {
            pathNodes.append(s.nodeID)
            if let edge = cameFromEdge[s] {
                pathEdges.append(edge)
            }
            cur = cameFromNode[s]
        }
        
        // Reconstruct from Origin -> Destination
        pathNodes.reverse()
        pathEdges.reverse()
        
        // Phase 12 & 13 & 14: Geometry, Distance, ETA
        var totalDistance: Double = 0
        var totalSeconds: Double = 0
        var geometry = [CLLocationCoordinate2D]()
        
        for edgeID in pathEdges {
            let edge = try database.edge(id: edgeID)
            totalDistance += edge.lengthMeters
            
            let speed = edge.speedKPH > 0 ? edge.speedKPH : 50.0 // fallback 50kph
            let speedMPS = speed * (1000.0 / 3600.0)
            totalSeconds += (edge.lengthMeters / speedMPS)
            
            let edgeCoords = try database.edgeGeometry(for: edgeID)
            
            if geometry.isEmpty {
                geometry.append(contentsOf: edgeCoords)
            } else {
                // To avoid duplicate shared points between edges
                if let first = edgeCoords.first, let lastGeom = geometry.last,
                   abs(first.latitude - lastGeom.latitude) < 0.00001 && abs(first.longitude - lastGeom.longitude) < 0.00001 {
                    geometry.append(contentsOf: edgeCoords.dropFirst())
                } else {
                    geometry.append(contentsOf: edgeCoords)
                }
            }
        }
        
        // Final fallback if missing initial coordinates
        if geometry.isEmpty {
            geometry = [startNode.coordinate, endNode.coordinate]
        }
        
        return Route(
            origin: origin,
            destination: destination,
            totalDistanceMeters: totalDistance,
            estimatedTravelTimeSeconds: totalSeconds,
            nodeIDs: pathNodes,
            edgeIDs: pathEdges,
            geometry: geometry
        )
    }
    
    private func heuristic(from start: RoadNode, to end: RoadNode) -> Double {
        let startLoc = CLLocation(latitude: start.coordinate.latitude, longitude: start.coordinate.longitude)
        let endLoc = CLLocation(latitude: end.coordinate.latitude, longitude: end.coordinate.longitude)
        // Return geographical great-circle distance as the admissible heuristic
        return startLoc.distance(from: endLoc)
    }
}
