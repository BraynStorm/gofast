const ARROW = ' ➤ ';

const TITLE_PLACEHOLDERS = [
    "“I have made this [letter] longer than usual because I have not had time to make it shorter.” —Blaise Pascal",
    "“It is my ambition to say in ten sentences what others say in a whole book.” ―Friedrich Nietzsche"
];
function random_title_placeholder() {
    const randomIndex = Math.floor(Math.random() * TITLE_PLACEHOLDERS.length);
    return TITLE_PLACEHOLDERS[randomIndex];
}

function display_key(key, max_key) {
    const padding = parseInt(Math.ceil(Math.log10(max_key + 1)));
    return '#' + `${key}`.padStart(padding, '0');
}

const DEBUG = console.log;


function fmt_time_exact(t) {
    const seconds = Number(t);
    const d = Math.floor(seconds / (3600 * 8));
    const h = Math.floor(seconds % (3600 * 8) / 3600);
    const m = Math.floor(seconds % 3600 / 60);
    const s = Math.floor(seconds % 60);

    const dDisplay = d > 0 ? (d + "d ") : "";
    const hDisplay = h > 0 ? (h + "h ") : "";
    const mDisplay = m > 0 ? (m + "m ") : "";
    const sDisplay = s > 0 ? (s + "s ") : "";
    return (dDisplay + hDisplay + mDisplay + sDisplay).trimEnd();
}
function fmt_time(t) {
    let seconds = Number(t);
    let negative = seconds < 0;
    let prefix = negative ? 'Underestimated by at least ' : '~';
    seconds = Math.abs(seconds);
    const d = Math.floor(seconds / (3600 * 8));
    const h = Math.floor(seconds % (3600 * 8) / 3600);
    const m = Math.floor(seconds % 3600 / 60);
    // const s = Math.floor(seconds % 60);

    const epsilon = 0.999;
    if (d > 0) {
        return prefix + Math.floor(d + epsilon) + "d";
    } else if (h > 0) {
        return prefix + Math.floor(h + epsilon) + "h";
    } else if (m > 0) {
        return prefix + Math.floor(m + epsilon) + "m";
    } else {
        if (seconds == 0) return 'Done'
        return `${seconds} s`
    }
}

function array_remove(array, item) {
    return array.splice(array.indexOf(item), 1);
}

// WebAssembly.instantiateStreaming(
//     fetch("/wasm")
// ).then(gofast_wasm => {
//     const gofast = gofast_wasm.instance.exports;
//     console.log(gofast);
//     const add = gofast.add;
//     console.log(add(1, 2));
// });

document.addEventListener("alpine:init", () => {
    Alpine.data("GOFAST", () => ({
        tickets: {},
        ticket_time: {
            estimate: {},
            spent: {},
        },
        names: {
            priority: [],
            type: [],
            status: [],
        },
        graph: {
            show: false,
            mode: 'time_left',
        },

        max_key: 0,

        main: {
            mode: Alpine.$persist('table'),
        },
        // Model: The ticket table.
        m_table: {
            search: {
                string: '',
                type: [],
                priority: [],
                status: [0, 1],
            },
            order: [
                ['priority', 1],
                ['status', 1],
                ['type', 1],
            ],
            highlight_key: 0,
        },
        // Model: New Ticket.
        m_nt: {
            show: false,
            title: "",
            description: "",
            parent: null,
            type: 0,
            status: 0,
            priority: 0,
        },
        // Model: Edit Ticket.
        m_et: {
            title: "",
            description: "",
            parent: null,
            type: 0,
            status: 0,
            priority: 0,
        },
        // Model: Tooltip
        m_tooltip: {
            key: 0,
            position: [0, 0],
        },

        left_panel: { mode: '' },
        right_panel: { mode: '' },
        reload() {
            fetch("/api/tickets").then(r => r.json()).then(r => {
                const count = r.count; // Not used yet, but shows how many elements were received.
                const max_key = r.max_key;
                this.names.priority = r.names.priorities;
                this.names.status = r.names.statuses;
                this.names.type = r.names.types;
                this.names.people = r.names.people;
                const keys = r.tickets.keys;
                const parents = r.tickets.parents;
                const titles = r.tickets.titles;
                const descriptions = r.tickets.descriptions;
                const types = r.tickets.types;
                const statuses = r.tickets.statuses;
                const priorities = r.tickets.priorities;
                const orders = r.tickets.orders;

                const creators = r.tickets.creators;
                const created_on = r.tickets.created_on;
                const last_updated_by = r.tickets.last_updated_by;
                const last_updated_on = r.tickets.last_updated_on;

                console.log(`-> /api/tickets -> ${keys.length}/${count} ticket(s), max_key=${max_key}`);

                const tickets = {};

                this.max_key = max_key;
                for (let i = 0; i < keys.length; ++i) {
                    const key = keys[i];
                    tickets[key] = {
                        key: key,
                        title: titles[i],
                        description: descriptions[i],
                        parent: parents[i],
                        /* TODO(bozho2):
                            Handle "negative"
                                types
                                statuses
                                priorities
                            as they are u8s in the backend.
                        */
                        type: types[i],
                        status: statuses[i],
                        priority: priorities[i],
                        order: orders[i],
                        creator: creators[i],
                        created_on: new Date(created_on[i]),
                        last_updated_by: last_updated_by[i],
                        last_updated_on: new Date(last_updated_on[i]),
                        children: [],
                    }

                }

                //- bs: connect the parent-child relationships.
                for (let i = 0; i < keys.length; ++i) {
                    const key = keys[i];
                    const ticket = tickets[key];
                    if (ticket.parent) {
                        tickets[ticket.parent].children.push(key);
                    }
                }

                // Load the ticket_time table.
                const ticket_times = r.ticket_time;
                const ticket_keys = ticket_times.tickets;
                const people = ticket_times.people;
                const estimates = ticket_times.estimates;
                const spent_ = ticket_times.spent;

                const ticket_time = { estimate: {}, spent: {} };
                for (let i = 0; i < ticket_keys.length; ++i) {
                    const key = ticket_keys[i];
                    const person = people[i];
                    const estimate = estimates[i];
                    const spent = spent_[i];

                    if (!(key in ticket_time.estimate)) {
                        ticket_time.estimate[key] = {};
                    }
                    if (!(key in ticket_time.spent)) {
                        ticket_time.spent[key] = {};
                    }

                    let e = ticket_time.estimate[key] || 0;
                    let ep = e[person] || 0;
                    ep += estimate;
                    ticket_time.estimate[key][person] = ep;

                    let s = ticket_time.spent[key] || 0;
                    let sp = s[person] || 0;
                    sp += spent;
                    ticket_time.spent[key][person] = sp;
                }

                this.tickets = tickets;
                this.ticket_time = ticket_time;

                /*TODO:
                    Implement a graph visualization of ticket relationships.
                    There are MANY useful ways to display these thing,
                    and we should probably let the user create custom views,
                    let the user navigate them.
                */
                // draw_graph(tickets, max_key);
            });
        },
        init() {
            this.reload();
        },
        likely_next_ticket_number() { return this.max_key + 1; },
        ui_create_ticket() {
            this.create_ticket(
                this.m_nt.title,
                this.m_nt.description,
                this.m_nt.parent,
                this.m_nt.type,
                this.m_nt.status,
                this.m_nt.priority,
            )

            /*TODO:
                Handle the case where the server responses with a failure and 
                we probably want to restore the sate of the box and show it to the
                user, explaining what happened.
            */
            this.m_nt.title = '';
            this.m_nt.description - '';
        },
        ui_hover_ticket(event, key) {
            if (this.m_tooltip.key !== key) this.m_tooltip.key = key;
            this.m_tooltip.position[0] = event.clientX;
            this.m_tooltip.position[1] = event.clientY;
        },
        ui_delete_ticket(key) {
            if (confirm(`Are you sure you want to delete ${this.display_key(key)}`)) {
                this.delete_ticket(key);
            } else {
                //TODO(joke): add a server-side counter 'saved-by-are-you-sure'.
            }
        },
        // Show only the tickets matching the search criteria.
        ui_filter_tickets() {
            const search = this.m_table.search;
            const order = this.m_table.order;

            const priorities = (search.priority);
            const types = (search.type);
            const statuses = (search.status);
            const check_priority = priorities.length > 0 && priorities.length < this.names.priority.length;
            const check_type = types.length > 0 && types.length < this.names.type.length;
            const check_status = statuses.length > 0 && statuses.length < this.names.status.length;

            let entries = Object.entries(this.tickets);
            // First 100
            // entries = entries.slice(0, 5000);
            // PERF: Okay, so my loading code is slow, not the AlpineJS DOM generation.
            entries = entries.filter(
                ([_, t]) => (
                    (!check_priority || priorities.includes(t.priority)) &&
                    (!check_status || statuses.includes(t.status)) &&
                    (!check_type || types.includes(t.type)) &&
                    true
                )
            );
            entries = entries.sort(
                ([ak, a], [bk, b]) => {
                    let r = 0;
                    for (const [s, o] of order) {
                        const v = a[s] * o - b[s] * o;
                        r += v;
                        if (v != 0) {
                            break;
                        }
                        /*PERF:
                            This is probably horrible...
                        */
                        if (s === 'priority') {
                            /* Special, we need to sort by 'order' as a secondary step. */
                            const v = a['order'] * o - b['order'] * o;
                            r += v;
                            if (v != 0) {
                                break;
                            }
                        }
                    }
                    return r;
                }
            );

            return entries;
        },
        /**
         * Called with the ticket key that has been manually reordered ("sorted")
         * (a.k.a. on drop event)
         * 
         * Position is a relative index in the current ui_filter_tickets() table.
         * Gets called **before** the modification of the sorting order.
         */
        ui_on_reorder_item_to(ticket, new_position) {
            let update = true;
            const sorted_tickets = this.ui_filter_tickets();
            const key = ticket.key;
            const old_position = sorted_tickets.findIndex(x => x[0] == key);

            console.log(`${key} moved from ${old_position} to ${new_position}`);

            // Figure out the the location of the new 
            if (new_position === 0) {
                // Top dog
                const below = sorted_tickets[0][1];
                if (below.priority !== ticket.priority) {
                    // We're above "all" other of the same priority.
                    ticket.priority = below.priority;
                }
                // We're above some other priority even, convert to it first.
                ticket.order = below.order - 1;
            } else if (new_position === sorted_tickets.length - 1) {
                // Dropped at the end of the current view.
                const above = sorted_tickets[sorted_tickets.length - 1][1];
                if (above.priority !== ticket.priority) {
                    // We're below "all" other of the same priority.
                    ticket.priority = above.priority;
                }
                ticket.order = above.order + 1;
            } else {
                const above = sorted_tickets[(old_position > new_position ? new_position - 1 : new_position)][1];
                const below = sorted_tickets[(old_position > new_position ? new_position : new_position + 1)][1];
                console.log(
                    `above=${above.key}[${above.order}], me=${key}, below=${below.key}[${below.order}]`
                )
                if (above.priority === below.priority) {
                    /* Update the priority as well */
                    if (ticket.priority !== above.priority) {
                        ticket.priority = above.priority;
                    }
                    ticket.order = (above.order + below.order) * 0.5;
                } else {
                    /* If at least on of our neighbours matches our priority,
                        we just position ourselves below them.
                    */
                    if (above.priority === ticket.priority) {
                        ticket.order = above.order + 1;
                    } else if (below.priority === ticket.priority) {
                        ticket.order = below.order - 1;
                    } else {
                        /* Well, neither of our neighbours is the same priority
                        as us... Don't  */
                        const np = this.names.priority;
                        const name_old = np[ticket.priority];
                        const name_above = np[above.priority];
                        const name_below = np[below.priority];
                        alert(`You dropped this '${name_old}' ticket between '${name_below}' and '${name_above}'.`)
                        /* TODO: Find a way to choose which priority to assign. Or somehow ask.

                        */
                        const order = ticket.order;
                        ticket.order = order + 1;
                        update = false;
                        this.$nextTick(() => {
                            ticket.order = order;
                        });
                    }
                }
            }

            if (update) {
                this.send_update_order(key);
            }
        },
        send_update_order(key) {
            console.log(`send_update_order(${key})`);
            const t = this.tickets[key];
            fetch(`/api/ticket/${key}`, {
                method: 'PATCH',
                headers: {
                    "Content-Type": "application/json",
                },
                body: JSON.stringify({
                    priority: t.priority,
                    order: t.order,
                })
            }).then(r => {
                if (!r.ok) {
                    console.log(`send_update_order(${key}) failed: ${r.status} - ${r.statusText}`);
                }
            });
        },
        create_ticket(
            title,
            description,
            maybe_parent,
            type,
            status,
            priority,
        ) {
            let ticket = {
                title: title,
                description: description,
                parent: maybe_parent,
                type: type,
                status: status,
                priority: priority,
            };
            const data = { ...ticket };

            // Assign a 'fake' ticket number - our best guess.
            ticket.key = this.likely_next_ticket_number();
            ticket.order = ticket.key;
            ticket.created_on = new Date();
            ticket.last_updated_on = ticket.created_on;
            ticket.created_by = 0; // TODO: Authentication.
            ticket.last_updated_by = 0;
            ticket.children = [];

            this.tickets[ticket.key] = ticket;

            fetch("/api/tickets", {
                method: "POST", body: JSON.stringify(data)
            }).then(async r => {
                const txt_response = await r.text();
                if (r.ok) {
                    const real_key = parseInt(txt_response);
                    const old_key = ticket.key;
                    if (old_key !== real_key) {
                        // Someone beat us to it. We've got to update the UI and internal data.
                        console.log(`create_ticket: replacing ${old_key} => ${real_key}`);

                        delete this.tickets[old_key];
                        ticket.key = real_key;
                        ticket.order = real_key;
                        this.tickets[ticket.key] = ticket;
                        this.tickets[ticket.parent].children.push(real_key);
                    }
                    this.max_key = real_key;
                    console.log("create_ticket: success");
                    this.m_nt.show = false;
                    // TODO: Also maybe clear it?
                } else {
                    console.log(`create_ticket: error: ${r.status}, ${txt_response}`);
                }
            });
        },
        delete_ticket(key) {
            console.log(`delete_ticket: Deleting ${key}`);
            const ticket_temp = this.tickets[key];
            const children_temp = [];

            // Preemptively remove the parent from all child-tickets,
            // but keep them around in case the request fails.
            for (let tk in this.tickets) {
                const ticket = this.tickets[tk];
                if (ticket.parent === key) {
                    console.log(`delete_ticket: clearing the parent of ${tk} - it was a child of ${key}`)
                    ticket.parent = null;
                    children_temp.push(tk);
                }
            }

            // Remove it preemptively.
            delete this.tickets[key];

            fetch(`/api/ticket/${key}`, {
                method: "DELETE",
            }).then(async r => {
                if (r.ok) {
                    console.log("delete_ticket: success");
                } else {
                    // Failed, restore it.
                    const txt = await r.text();
                    console.log(`delete_ticket: error: ${r.status}, ${txt}`)
                    this.max_key = this.max_key;
                    this.tickets[key] = ticket_temp;

                    // Restore the children.
                    for (let child in children_temp) {
                        this.tickets[child].parent = key;
                    }
                }
            });
        },
        edit_ticket(key) {
            this.m_table.highlight_key = key;
            this.left_panel.mode = 'edit';

            /*NOTE:
                If I don' use $nextTick, the parent dropdown always begins
                as "No parent" the first time the panel is opened.

                No idea why.
            */
            this.$nextTick(() => {
                this.m_et = { ... this.tickets[key] };
            })
            this.graph_update();
        },
        direct_children(key) {
            return this.tickets[key].children || [];
        },
        all_children() {
            const tickets = this.tickets;
            const graph_children = {};
            for (const ticket_key in tickets) {
                graph_children[ticket_key] = [];
            }
            for (const ticket_key in tickets) {
                const ticket = tickets[ticket_key];
                if (ticket.parent !== null)
                    graph_children[ticket.parent].push(ticket_key);
            }
            return graph_children;
        },
        ticket_subgraph(key, include_my_parents) {
            const all = this.all_children();
            const subgraph = {};

            let not_expanded = [key];
            while (not_expanded.length > 0) {
                const buffer = [];
                for (const key of not_expanded) {
                    const children = all[key];
                    buffer.push(...children);
                    subgraph[key] = children;
                }
                not_expanded = buffer;
            }

            /* Include my parents and grand-parents but don't include their
            other children. */
            if (include_my_parents) {
                const tickets = this.tickets;
                let child = key;
                let parent = tickets[child].parent;
                while (parent !== null) {
                    subgraph[parent] = [child];
                    child = parent;
                    parent = tickets[parent].parent;
                }
                // Return the grandparent as a second value.
                return [subgraph, child];
            } else {
                return subgraph;
            }

        },
        graph_update() {
            const key = this.m_table.highlight_key;
            if (this.graph.show && key > 0)
                this.graph_draw_ticket_children(key);
        },
        graph_draw_ticket_children(ticket) {
            /*
            Provides an object with keys = parent, values = array of children,
            Contains only keys!
            */
            const subgraph = this.ticket_subgraph(ticket, false);
            const tickets = Alpine.raw(this.tickets);
            const compute_progress = x => this.progress(x);
            const mode = this.graph.mode;

            let progress = {};
            function ticket_progress(key) {
                if (!(key in progress)) {
                    const children = subgraph[key];
                    let my_progress = compute_progress(key);
                    for (let child_index in children) {
                        const child_progress = ticket_progress(children[child_index]);
                        my_progress.spent += child_progress.spent;
                        my_progress.estimate += child_progress.estimate;
                    }
                    progress[key] = my_progress;
                    return my_progress;
                } else {
                    return progress[key];
                }
            }

            function key_to_ticket(key) {
                const children = subgraph[key].map(key_to_ticket)
                let ticket = {
                    ticket: tickets[key],
                    progress: ticket_progress(key),
                };
                if (children.length > 0) {
                    ticket.children = children;
                }
                return ticket;
            }

            let data = key_to_ticket(ticket);
            if (!data.children) {
                data.children = [];
            }


            // Specify the chart’s dimensions.
            const width = container.clientWidth;
            const height = 300;
            const visible = 5;

            // Create the color scale.
            const color = d3.scaleOrdinal(d3.quantize(d3.interpolateRainbow, data.children.length + 1));

            let fn_sum = undefined;
            let value_name = undefined;
            if (mode == 'time_left') {
                value_name = 'Work left';
                fn_sum = d => {
                    const p = ticket_progress(d.ticket.key);
                    return Math.max(0, p.estimate - p.spent);
                };
            } else if (mode == 'estimated') {
                value_name = 'Estimated';
                fn_sum = d => {
                    const p = ticket_progress(d.ticket.key);
                    return Math.max(0, p.estimate);
                };
            }

            // Compute the layout.
            const hierarchy = d3.hierarchy(data)
                .sum(fn_sum)
                .sort((a, b) => b.height - a.height || b.value - a.value);
            const root = d3.partition()
                .size([height, (hierarchy.height + 1) * width / visible])
                (hierarchy);

            // Create the SVG container.
            const svg = d3.create("svg")
                .attr("viewBox", [0, 0, width, height])
                .attr("width", width)
                .attr("height", height)
                .attr("style", "max-width: 100%; height: auto;");
            container.replaceChildren(svg.node());

            // Append cells.
            const cell = svg
                .selectAll("g")
                .data(root.descendants())
                .join("g")
                .attr("transform", d => `translate(${d.y0},${d.x0})`);

            const rect = cell.append("rect")
                .attr("width", d => d.y1 - d.y0 - 1)
                .attr("height", d => rectHeight(d))
                .attr("fill-opacity", 0.6)
                .attr("fill", d => {
                    if (!d.depth) return "#ccc";
                    while (d.depth > 1) d = d.parent;
                    return color(d.data.name);
                })
                .style("cursor", "pointer")
                .on("click", clicked);

            function wrap(text, width) {
                text.each(function () {
                    var text = d3.select(this),
                        words = text.text().split(/\s+/).reverse(),
                        word,
                        line = [],
                        lineNumber = 0,
                        lineHeight = 1.1, // ems
                        x = text.attr("x"),
                        y = text.attr("y"),
                        dy = 0, //parseFloat(text.attr("dy")),
                        tspan = text.text(null)
                            .append("tspan")
                            .attr("x", x)
                            .attr("y", y)
                            .attr("dy", dy + "em");
                    while (word = words.pop()) {
                        line.push(word);
                        tspan.text(line.join(" "));
                        if (tspan.node().getComputedTextLength() > width) {
                            line.pop();
                            tspan.text(line.join(" "));
                            line = [word];
                            tspan = text.append("tspan")
                                .attr("x", x)
                                .attr("y", y)
                                .attr("dy", ++lineNumber * lineHeight + dy + "em")
                                .text(word);
                        }
                    }
                });
            }

            const format = fmt_time

            const text = cell.append("text")
                .style("user-select", "none")
                .attr("pointer-events", "none")
                .attr("x", 10)
                .attr("y", 13 * 5)
                .attr("fill-opacity", d => +labelVisible(d))
                .text(d => d.data.ticket.title)
                .call(wrap, rect.attr('width') - 10);

            text.append("tspan")
                .attr("x", 10)
                .attr("y", 13 * 1)
                .text(d => this.display_key(d.data.ticket.key))

            const tspan = text.append("tspan")
                .attr("x", 10)
                .attr("y", 13 * 2)
                .attr("fill-opacity", d => labelVisible(d) * 0.7)
                .text(d => {
                    if (d.children)
                        return `${value_name}${d.children ? '(incl. children)' : ''}: ${format(d.value)}`
                    else
                        return `${value_name}: ${format(d.value)}`
                });

            const tspan2 = text.append("tspan")
                .attr("x", 10)
                .attr("y", 13 * 3)
                .attr("fill-opacity", d => labelVisible(d) * 0.7)
                .text(d => {
                    const prog = this.progress(d.data.ticket.key);
                    DEBUG(prog)
                    return `Standalone: S:${format(prog.spent)} E:${format(prog.estimate)}`;
                });

            cell.append("title")
                .text(d => `${d.ancestors().map(d => this.display_key(d.data.ticket.key)).reverse().join("/")}\n${format(d.value)}`);

            // On click, change the focus and transitions it into view.
            let focus = root;
            function clicked(event, p) {
                if (p.parent === null) return;
                focus = focus === p ? p = p.parent : p;

                root.each(d => d.target = {
                    x0: (d.x0 - p.x0) / (p.x1 - p.x0) * height,
                    x1: (d.x1 - p.x0) / (p.x1 - p.x0) * height,
                    y0: d.y0 - p.y0,
                    y1: d.y1 - p.y0
                });

                const t = cell.transition().duration(750)
                    .attr("transform", d => `translate(${d.target.y0},${d.target.x0})`);

                rect.transition(t).attr("height", d => rectHeight(d.target));
                text.transition(t).attr("fill-opacity", d => +labelVisible(d.target));
                tspan.transition(t).attr("fill-opacity", d => labelVisible(d.target) * 0.7);
                tspan2.transition(t).attr("fill-opacity", d => labelVisible(d.target) * 0.7);
            }

            function rectHeight(d) {
                return d.x1 - d.x0 - Math.min(1, (d.x1 - d.x0) / 2);
            }

            function labelVisible(d) {
                return d.y1 <= width && d.y0 >= 0 && d.x1 - d.x0 > 3 * 13;
            }

        },
        stop_edit_ticket(save) {
            if (this.left_panel.mode === 'edit') this.left_panel.mode = '';
            this.m_table.highlight_key = 0;

            if (save) {
                /*TODO:
                    1. Save the data locally, keeping a shadow-copy in case of failure.
                    2. Save the data on the server.
                */

                const edited = this.m_et;
                const key = edited.key;
                const old = this.tickets[key];
                const data = {};

                const noop = x => x;
                const fields = [
                    ['title', noop],
                    ['description', noop],
                    ['parent', x => x == null ? null : parseInt(x)],
                    ['type', parseInt],
                    ['status', parseInt],
                    ['priority', parseInt],
                ]

                const shadow_copy = {}

                for (const [field, transform] of fields) {
                    const edited_value = transform(edited[field]);
                    if (edited_value !== old[field]) {
                        data[field] = edited_value;
                        shadow_copy[field] = old[field];
                        old[field] = edited_value;
                    }
                }

                fetch(`/api/ticket/${key}`, {
                    method: "PATCH",
                    headers: {
                        "Content-Type": "application/json",
                    },
                    body: JSON.stringify(data)
                }).then(r => {
                    if (!r.ok) {
                        console.log(`stop_edit_ticket: error: ${r.status} - ${r.statusText}`);
                        // restore the old data.
                        for (const field of fields) {
                            old[field] = shadow_copy[field];
                        }
                    }
                })
            }
        },
        /** `1` becomes `#001` */
        display_key(key) {
            return display_key(key, this.max_key);
        },
        /** For ticket 1 with parent 21, returns `#021 -> #001` */
        display_key_with_parent(key) {
            const parent = this.tickets[key].parent;
            let s = "";
            if (parent) {
                s = this.display_key_with_parent(parent) + ARROW;
            }

            return s + display_key(key);
        },
        /* Returns a URL of the icon for the given priority */
        priority_icon(priority_id) {
            /*TODO:
                Map priority->image on the server.
            */
            return `/static/ui/icons/priority_${priority_id - 4}.svg`;
        },
        type_icon(type_id) {
            return `/static/ui/icons/type_${type_id}.svg`;
        },
        priority_name(priority_id) {
            return this.names.priority[priority_id];
        },
        status_name(status_id) {
            return this.names.status[status_id];
        },
        type_name(type_id) {
            return this.names.type[type_id];
        },
        double_quotes(s) {
            return '"' + s + '"'
        },
        progress(key) {
            const estimate = this.ticket_time.estimate[key];
            const spent = this.ticket_time.spent[key];

            let ticket_estimate = 0;
            let ticket_spent = 0;
            for (p in estimate) {
                ticket_estimate += estimate[p];
            }
            for (p in spent) {
                ticket_spent += spent[p];
            }
            return { spent: ticket_spent, estimate: ticket_estimate };
        },
        progress_pct(key) {
            const p = this.progress(key);
            if (p.estimate == 0) return 0;
            return p.spent / p.estimate;
        },
        ui_highlight_key(key) {
            this.m_table.highlight_key = key;
        },
        class_highlighted(key) {
            return this.m_table.highlight_key == key ? "highlight" : "";
        },
    }));
});