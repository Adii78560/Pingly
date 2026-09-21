import osmium
import sqlite3
import sys
import os
import time
import math
import struct
from collections import defaultdict

# ---------------------------------------------------------
# CONSTANTS & PROFILES
# ---------------------------------------------------------
CAR_HIGHWAY_TAGS = {
    'motorway', 'motorway_link',
    'trunk', 'trunk_link',
    'primary', 'primary_link',
    'secondary', 'secondary_link',
    'tertiary', 'tertiary_link',
    'unclassified', 'residential', 'living_street'
}

CAR_RESTRICTED_ACCESS = {'no', 'private', 'agricultural', 'forestry', 'delivery'}

DEFAULT_SPEEDS = {
    'motorway': 120,
    'motorway_link': 80,
    'trunk': 100,
    'trunk_link': 60,
    'primary': 80,
    'primary_link': 50,
    'secondary': 60,
    'secondary_link': 40,
    'tertiary': 50,
    'tertiary_link': 30,
    'unclassified': 40,
    'residential': 30,
    'living_street': 10
}

# ---------------------------------------------------------
# UTILS
# ---------------------------------------------------------
def haversine(lat1, lon1, lat2, lon2):
    R = 6371000  # radius of Earth in meters
    phi1 = math.radians(lat1)
    phi2 = math.radians(lat2)
    delta_phi = math.radians(lat2 - lat1)
    delta_lambda = math.radians(lon2 - lon1)
    a = math.sin(delta_phi / 2.0) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(delta_lambda / 2.0) ** 2
    c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a))
    return R * c

def encode_geometry(coords):
    # Header: 'EG' (2 bytes), Version (1 byte), Count (4 bytes)
    # Payload: Int32 Lat, Int32 Lon (microdegrees)
    count = len(coords)
    header = struct.pack('<2sBI', b'EG', 1, count)
    payload = b''
    for lat, lon in coords:
        lat_int = int(round(lat * 1_000_000))
        lon_int = int(round(lon * 1_000_000))
        payload += struct.pack('<ii', lat_int, lon_int)
    return header + payload

def parse_speed(speed_str, road_class):
    if not speed_str:
        return DEFAULT_SPEEDS.get(road_class, 50)
    # Very basic parsing, e.g. "50", "30 mph"
    speed_str = speed_str.lower().strip()
    try:
        if 'mph' in speed_str:
            return int(float(speed_str.replace('mph', '').strip()) * 1.60934)
        return int(speed_str)
    except:
        return DEFAULT_SPEEDS.get(road_class, 50)

# ---------------------------------------------------------
# HANDLERS
# ---------------------------------------------------------
class Phase1Handler(osmium.SimpleHandler):
    """
    Pass 1: Collect valid routing ways and their nodes, and collect turn restrictions.
    """
    def __init__(self):
        super().__init__()
        self.valid_ways = set()
        self.node_ids = set() # nodes that belong to a valid way
        self.way_metadata = {}
        self.restrictions = []
        
        # Bounding box
        self.min_lat = 90.0
        self.max_lat = -90.0
        self.min_lon = 180.0
        self.max_lon = -180.0

    def way(self, w):
        highway = w.tags.get('highway')
        if highway not in CAR_HIGHWAY_TAGS:
            return
            
        access = w.tags.get('access')
        motor_vehicle = w.tags.get('motor_vehicle') or w.tags.get('motorcar')
        
        if access in CAR_RESTRICTED_ACCESS:
            if motor_vehicle not in ('yes', 'designated', 'permissive'):
                return
                
        self.valid_ways.add(w.id)
        
        way_nodes = [n.ref for n in w.nodes]
        self.node_ids.update(way_nodes)
        
        oneway_tag = w.tags.get('oneway', 'no')
        is_oneway = oneway_tag in ('yes', 'true', '1', '-1')
        oneway_reverse = oneway_tag == '-1'
        
        self.way_metadata[w.id] = {
            'nodes': way_nodes,
            'highway': highway,
            'name': w.tags.get('name', ''),
            'maxspeed': w.tags.get('maxspeed', ''),
            'is_oneway': is_oneway,
            'oneway_reverse': oneway_reverse
        }

    def relation(self, r):
        if r.tags.get('type') == 'restriction':
            restr_type = r.tags.get('restriction')
            if not restr_type:
                return
            
            from_way = None
            to_way = None
            via_node = None
            
            for member in r.members:
                if member.role == 'from' and member.type == 'w':
                    from_way = member.ref
                elif member.role == 'to' and member.type == 'w':
                    to_way = member.ref
                elif member.role == 'via' and member.type == 'n':
                    via_node = member.ref
                    
            if from_way and to_way and via_node:
                self.restrictions.append({
                    'relation_id': r.id,
                    'from_way': from_way,
                    'to_way': to_way,
                    'via_node': via_node,
                    'type': restr_type
                })


class Phase2Handler(osmium.SimpleHandler):
    """
    Pass 2: Extract coordinates for the nodes collected in Pass 1.
    """
    def __init__(self, node_ids, cursor):
        super().__init__()
        self.node_ids = node_ids
        self.cursor = cursor
        self.node_coords = {}
        
        self.min_lat = 90.0
        self.max_lat = -90.0
        self.min_lon = 180.0
        self.max_lon = -180.0

    def node(self, n):
        if n.id in self.node_ids:
            lat, lon = n.location.lat, n.location.lon
            self.node_coords[n.id] = (lat, lon)
            self.cursor.execute("INSERT INTO nodes (id, lat, lon) VALUES (?, ?, ?)", (n.id, lat, lon))
            self.cursor.execute("INSERT INTO rtree_nodes (id, minLat, maxLat, minLon, maxLon) VALUES (?, ?, ?, ?, ?)", 
                                (n.id, lat, lat, lon, lon))
            
            self.min_lat = min(self.min_lat, lat)
            self.max_lat = max(self.max_lat, lat)
            self.min_lon = min(self.min_lon, lon)
            self.max_lon = max(self.max_lon, lon)


def build_graph(way_metadata, node_coords, cursor):
    """
    Phase 3: Build Edges and Geometry
    """
    # Find intersection nodes to split ways into topological edges
    node_usage = defaultdict(int)
    for way_id, meta in way_metadata.items():
        nodes = meta['nodes']
        if nodes:
            node_usage[nodes[0]] += 2
            node_usage[nodes[-1]] += 2
            for n_id in nodes[1:-1]:
                node_usage[n_id] += 1
                
    intersection_nodes = {n_id for n_id, count in node_usage.items() if count >= 2}
    
    edge_id_counter = 1
    # We will map (way_id, start_node, end_node) -> edge_id for restriction resolution later
    # Note: Because of two-way roads, we store directed edges. A restriction applies to from_way -> to_way over a via_node.
    
    for way_id, meta in way_metadata.items():
        nodes = meta['nodes']
        highway = meta['highway']
        speed = parse_speed(meta['maxspeed'], highway)
        name = meta['name']
        is_oneway = meta['is_oneway']
        oneway_reverse = meta['oneway_reverse']
        
        segments = []
        current_segment = [nodes[0]]
        for n_id in nodes[1:-1]:
            current_segment.append(n_id)
            if n_id in intersection_nodes:
                segments.append(current_segment)
                current_segment = [n_id]
        current_segment.append(nodes[-1])
        segments.append(current_segment)
        
        for seg in segments:
            if len(seg) < 2:
                continue
                
            length_m = 0.0
            coords = []
            for i in range(len(seg)):
                c1 = node_coords.get(seg[i])
                if not c1:
                    break
                coords.append(c1)
                if i > 0:
                    c0 = node_coords.get(seg[i-1])
                    if c0:
                        length_m += haversine(c0[0], c0[1], c1[0], c1[1])
            
            if len(coords) < 2:
                continue
                
            u = seg[0]
            v = seg[-1]
            
            def insert_edge(u_node, v_node, geom_coords):
                nonlocal edge_id_counter
                geom_blob = encode_geometry(geom_coords)
                cursor.execute("""
                    INSERT INTO edges (edge_id, osm_way_id, u, v, length_m, speed_kph, road_class, name, oneway) 
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, (edge_id_counter, way_id, u_node, v_node, length_m, speed, highway, name, 1 if is_oneway else 0))
                cursor.execute("INSERT INTO edge_geometry (edge_id, geometry) VALUES (?, ?)", (edge_id_counter, geom_blob))
                edge_id_counter += 1

            if is_oneway:
                if oneway_reverse:
                    insert_edge(v, u, coords[::-1])
                else:
                    insert_edge(u, v, coords)
            else:
                insert_edge(u, v, coords)
                insert_edge(v, u, coords[::-1])

def resolve_restrictions(restrictions, cursor):
    """
    Phase 4: Resolve Turn Restrictions
    """
    for r in restrictions:
        rel_id = r['relation_id']
        fw = r['from_way']
        tw = r['to_way']
        via = r['via_node']
        rtype = r['type']
        
        cursor.execute("""
            INSERT INTO turn_restrictions (restriction_id, osm_relation_id, from_way_id, to_way_id, via_node_id, restriction_type)
            VALUES (NULL, ?, ?, ?, ?, ?)
        """, (rel_id, fw, tw, via, rtype))
        
        # Internal restricted_turns
        # Find edges entering via_node from from_way_id
        cursor.execute("SELECT edge_id FROM edges WHERE osm_way_id = ? AND v = ?", (fw, via))
        from_edges = [row[0] for row in cursor.fetchall()]
        
        # Find edges leaving via_node to to_way_id
        cursor.execute("SELECT edge_id FROM edges WHERE osm_way_id = ? AND u = ?", (tw, via))
        to_edges = [row[0] for row in cursor.fetchall()]
        
        type_int = 1 if rtype.startswith('only_') else 0 # 0=NO_TURN, 1=ONLY_TURN
        
        for fe in from_edges:
            for te in to_edges:
                cursor.execute("INSERT INTO restricted_turns (from_edge, to_edge, restriction_type) VALUES (?, ?, ?)", 
                               (fe, te, type_int))

def main():
    if len(sys.argv) < 3:
        print("Usage: python3 osm_to_rgraph.py <input.osm.pbf> <output.rgraph.sqlite>")
        sys.exit(1)
        
    pbf_file = sys.argv[1]
    sqlite_file = sys.argv[2]
    
    if os.path.exists(sqlite_file):
        os.remove(sqlite_file)
        
    conn = sqlite3.connect(sqlite_file)
    cur = conn.cursor()
    
    print("[Phase 0] Setup schema...")
    cur.executescript("""
        CREATE TABLE metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        CREATE TABLE region (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            min_lat REAL NOT NULL,
            max_lat REAL NOT NULL,
            min_lon REAL NOT NULL,
            max_lon REAL NOT NULL
        );
        CREATE TABLE nodes (
            id INTEGER PRIMARY KEY,
            lat REAL NOT NULL,
            lon REAL NOT NULL
        );
        CREATE TABLE edges (
            edge_id INTEGER PRIMARY KEY,
            osm_way_id INTEGER NOT NULL,
            u INTEGER NOT NULL,
            v INTEGER NOT NULL,
            length_m REAL NOT NULL,
            speed_kph INTEGER NOT NULL,
            road_class TEXT NOT NULL,
            name TEXT,
            oneway INTEGER NOT NULL DEFAULT 0,
            FOREIGN KEY(u) REFERENCES nodes(id),
            FOREIGN KEY(v) REFERENCES nodes(id)
        );
        CREATE TABLE edge_geometry (
            edge_id INTEGER PRIMARY KEY,
            geometry BLOB NOT NULL,
            FOREIGN KEY(edge_id) REFERENCES edges(edge_id)
        );
        CREATE TABLE turn_restrictions (
            restriction_id INTEGER PRIMARY KEY AUTOINCREMENT,
            osm_relation_id INTEGER NOT NULL,
            from_way_id INTEGER NOT NULL,
            to_way_id INTEGER NOT NULL,
            via_node_id INTEGER,
            restriction_type TEXT NOT NULL
        );
        CREATE TABLE restricted_turns (
            from_edge INTEGER NOT NULL,
            to_edge INTEGER NOT NULL,
            restriction_type INTEGER NOT NULL,
            FOREIGN KEY(from_edge) REFERENCES edges(edge_id),
            FOREIGN KEY(to_edge) REFERENCES edges(edge_id)
        );
        CREATE VIRTUAL TABLE rtree_nodes USING rtree(
            id, minLat, maxLat, minLon, maxLon
        );
    """)
    conn.commit()
    
    print("[Phase 1] Pass 1: Filtering ways and relations...")
    h1 = Phase1Handler()
    h1.apply_file(pbf_file, locations=False)
    print(f"  Valid ways found: {len(h1.valid_ways)}")
    print(f"  Nodes referenced: {len(h1.node_ids)}")
    print(f"  Turn restrictions found: {len(h1.restrictions)}")
    
    print("[Phase 2] Pass 2: Extracting nodes and building R-Tree...")
    h2 = Phase2Handler(h1.node_ids, cur)
    h2.apply_file(pbf_file, locations=False)
    conn.commit()
    
    print("[Phase 3] Building graph edges and geometry...")
    build_graph(h1.way_metadata, h2.node_coords, cur)
    conn.commit()
    
    print("[Phase 4] Resolving turn restrictions...")
    resolve_restrictions(h1.restrictions, cur)
    
    print("[Phase 0] Finalizing metadata and indexes...")
    cur.execute("INSERT INTO region (id, min_lat, max_lat, min_lon, max_lon) VALUES (1, ?, ?, ?, ?)",
                (h2.min_lat, h2.max_lat, h2.min_lon, h2.max_lon))
                
    cur.execute("SELECT COUNT(*) FROM nodes")
    node_count = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM edges")
    edge_count = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM edges WHERE oneway = 1")
    oneway_count = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM turn_restrictions")
    restriction_count = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM edge_geometry")
    geometry_count = cur.fetchone()[0]
    
    metadata = {
        'schema_version': '1',
        'graph_version': time.strftime("%Y-%m-%d"),
        'region_id': 'custom_extract',
        'region_name': 'Custom Region',
        'source': pbf_file,
        'source_timestamp': time.strftime("%Y-%m-%dT%H:%M:%SZ"),
        'generator_version': 'relyvo-osm-pipeline-1.0',
        'profile': 'car',
        'node_count': str(node_count),
        'edge_count': str(edge_count),
        'restriction_count': str(restriction_count)
    }
    
    for k, v in metadata.items():
        cur.execute("INSERT INTO metadata (key, value) VALUES (?, ?)", (k, v))
        
    cur.executescript("""
        CREATE INDEX idx_edges_u ON edges(u);
        CREATE INDEX idx_edges_v ON edges(v);
        CREATE INDEX idx_edges_way ON edges(osm_way_id);
        CREATE INDEX idx_nodes_lat_lon ON nodes(lat, lon);
        CREATE INDEX idx_restricted_from ON restricted_turns(from_edge);
    """)
    conn.commit()
    
    print("[Phase 4] Verifying database integrity...")
    cur.execute("PRAGMA integrity_check;")
    integrity = cur.fetchone()[0]
    print(f"  SQLite integrity_check: {integrity}")
    
    cur.execute("SELECT rtreecheck('rtree_nodes');")
    rtree_integrity = cur.fetchone()[0]
    print(f"  R-Tree rtreecheck: {rtree_integrity}")
    
    print("[Phase 4] Optimizing with VACUUM...")
    cur.execute("VACUUM;")
    conn.commit()
    
    file_size = os.path.getsize(sqlite_file) / (1024 * 1024)
    print(f"\\n--- Database Summary ---")
    print(f"Region: {metadata['region_name']}")
    print(f"Profile: {metadata['profile']}")
    print(f"Node count: {node_count}")
    print(f"Edge count: {edge_count}")
    print(f"One-way edges: {oneway_count}")
    print(f"Restrictions: {restriction_count}")
    print(f"Geometry records: {geometry_count}")
    print(f"Database size: {file_size:.2f} MB")
    
    conn.close()

if __name__ == '__main__':
    main()
