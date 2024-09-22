const Color_GraphProgress = "#DC6504";


function draw_graph(tickets, max_key) {
    /*TODO:
        Make this dynamic somehow.
    */
    const width = 900;

    // Compute the tree height; this approach will allow the height of the
    // SVG to scale according to the breadth (width) of the tree layout.

    let values = Object.values(tickets).map(t => {
        let o = { ...t };
        o.parent = (o.parent || 0);
        return o;
    });
    values.push({ key: 0, title: '' });
    const root = d3.stratify().id(t => t.key).parentId(t => t.parent)(values);
    const dx = 24;
    const dy = width / (root.height + 1);

    // Create a tree layout.
    const tree = d3.tree().nodeSize([dx, dy]);

    // Sort the tree and apply the layout.
    root.sort((a, b) => d3.ascending(a.data.key, b.data.key));
    tree(root);

    // Compute the extent of the tree. Note that x and y are swapped here
    // because in the tree layout, x is the breadth, but when displayed, the
    // tree extends right rather than down.
    let x0 = Infinity;
    let x1 = -x0;
    root.each(d => {
        if (d.x > x1) x1 = d.x;
        if (d.x < x0) x0 = d.x;
    });

    const prog = (d => d.key / 100);

    // Compute the adjusted height of the tree.
    const height = x1 - x0 + dx * 2;

    const svg = d3.create("svg")
        .attr("width", width)
        .attr("height", height)
        .attr("viewBox", [-dy / 3, x0 - dx, width, height])
        .attr("style", "max-width: 100%; height: auto; font: 10px sans-serif;");

    const link = svg.append("g")
        .attr("fill", "none")
        .attr("stroke", "#555")
        .attr("stroke-opacity", 0.4)
        .attr("stroke-width", 1.5)
        .selectAll()
        .data(root.links())
        .join("path")
        .attr("d", d3.linkHorizontal()
            .x(d => d.y)
            .y(d => d.x));

    const node = svg.append("g")
        .attr("stroke-linejoin", "round")
        .attr("stroke-width", 3)
        .selectAll()
        .data(root.descendants())
        .join("g")
        .attr("transform", d => `translate(${d.y},${d.x})`);

    const r_dot = 10;
    const r_dot_prog = r_dot * 0.90;
    node.append("circle")
        .attr("fill", d => d.children ? "#555" : "#999")
        .attr("r", r_dot);

    node.append("path")
        .attr("fill", Color_GraphProgress)
        .attr("d", d3.arc()
            .innerRadius(2.5)
            .outerRadius(r_dot_prog)
            .startAngle(0)
            .endAngle(d => Math.PI * 2 * (d.data.key / 22))
        );
    node.append("text")
        .attr("dy", "0.31em")
        .attr("x", d => d.children ? -22 : 22)
        .attr("text-anchor", d => d.children ? "end" : "start")
        .text(d => display_key(d.data.key, max_key) + ' ' + d.data.title.substring(0, 24))
        .attr("stroke", "white")
        .attr("paint-order", "stroke");

    container.replaceChildren(svg.node());
}