meta:
  id: gofast_filesystem_v0
  file-extension: gfs
  endian: le
seq:
  - id: header
    type: header
  - id: version
    type: version
  - id: names
    type: names
  - id: tickets
    type: tickets
  - id: graphs
    type: graphs
  - id: ticket_times
    type: ticket_times
types:
  header:
    seq:
      - id: magic
        contents: 'GOFAST'
      - id: magic_null
        contents: [0x00]
  version:
    seq:
      - id: version
        type: u4
      
  string:
    seq:
      - id: length
        type: u4
      - id: data
        type: str
        size: length
        encoding: UTF8
  string_array:
    seq:
      - id: count
        type: u8
      - id: strings
        type: string
        repeat: expr
        repeat-expr: count
  names:
    seq:
      - id: types
        type: string_array
      - id: priorities
        type: string_array
      - id: statuses
        type: string_array
      - id: people
        type: string_array
  details:
    seq:
      - id: type
        type: u1
      - id: status
        type: u1
      - id: priority
        type: u1
      - id: order
        type: f4
  tickets:
    seq:
      - id: max_key
        type: u4
      - id: count
        type: u4
      - id: keys
        type: u4
        repeat: expr
        repeat-expr: count
      - id: details
        type: details
        repeat: expr
        repeat-expr: count
      - id: creator
        type: u4
        repeat: expr
        repeat-expr: count
      - id: created_on
        type: s8
        repeat: expr
        repeat-expr: count
      - id: last_updated_by
        type: u4
        repeat: expr
        repeat-expr: count
      - id: updated_on
        type: s8
        repeat: expr
        repeat-expr: count
      - id: titles
        type: string
        repeat: expr
        repeat-expr: count
      - id: descriptions
        type: string
        repeat: expr
        repeat-expr: count
  graphs:
    seq:
      - id: count
        type: u8
      - id: graphs
        type: anygraph
        repeat: expr
        repeat-expr: count
  anygraph:
    seq:
      - id: type
        type: u1
      - id: count
        type: u8
      - id: children
        type: graph_children
        if: type == 0
        repeat: expr
        repeat-expr: count
      
  graph_children:
    seq:
      - id: from
        type: u4
      - id: to
        type: u4
        repeat: expr
        repeat-expr: 16
      
  ticket_times:
    seq:
      - id: count
        type: u8
      - id: tt
        type: ticket_time
        repeat: expr
        repeat-expr: count
  ticket_time:
    seq:
      - id: ticket
        type: u4
      - id: person
        type: u4
      - id: estimate
        type: u4
      - id: spent
        type: u4
