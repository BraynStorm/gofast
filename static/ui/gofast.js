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
    const seconds = Number(t);
    const d = Math.floor(seconds / (3600 * 8));
    const h = Math.floor(seconds % (3600 * 8) / 3600);
    const m = Math.floor(seconds % 3600 / 60);
    // const s = Math.floor(seconds % 60);

    const epsilon = 0.999;
    if (d > 0) {
        return "~" + Math.floor(d + epsilon) + "d";
    } else if (h > 0) {
        return "~" + Math.floor(h + epsilon) + "h";
    } else if (m > 0) {
        return "~" + Math.floor(m + epsilon) + "m";
    } else {
        return ""
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

        max_key: 0,

        // Model: The ticket table.
        m_table: {
            search: {
                string: '',
                priority: [],
                status: [],
                type: [],
            },
            order: [
                ['priority', 1],
                ['order', 1], // Temporary as fuck
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
            maybe_parent: null,
            type: 0,
            priority: 0,
            status: 0,
        },
        // Model: Edit Ticket.
        m_et: {
            title: "",
            description: "",
            parent: null,
            type: 0,
            priority: 0,
            status: 0,
        },
        // Model: Tooltip
        m_tooltip: {
            key: 0,
            position: [0, 0],
        },

        inset: {
            // Kinda external to the rest of the fields. 
            mode: 'create',
            create: {},
        },
        left_panel: { mode: '' },
        right_panel: { mode: '' },
        reload() {
            fetch("/api/tickets").then(r => r.json()).then(r => {
                const count = r.count; // Not used yet, but shows how many elements were received.
                const max_key = r.max_key;
                this.names.priority = r.name_priorities;
                this.names.status = r.name_statuses;
                this.names.type = r.name_types;
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
                        /* NOTE(bozho2):
                            Experiment!
                        */
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
                this.m_nt.maybe_parent,
            )
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
                    }
                    return r;
                }
            );

            // const result = Object.fromEntries(entries);
            return entries.map(([k, t]) => [parseInt(k), t]);
        },
        ui_should_enable_reorder() {
            return this.m_table.order[0][0] === 'priority';
        },
        /**
         * Called with the ticket key that has been manually reordered ("sorted")
         * (a.k.a. on drop event)
         * 
         * Position is a relative index in the current ui_filter_tickets() table.
         * Gets called **before** the modification of the sorting order.
         */
        ui_on_reorder_item_to(ticket, new_position) {
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
                if (above.priority == below.priority) {
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
                        ticket.order = above.order - 1;
                    } else {
                        /* Well, neither of our neighbours is the same priority
                        as us... Don't  */
                        const np = this.names.priority;
                        const name_old = np[ticket.priority];
                        const name_above = np[above.priority];
                        const name_below = np[below.priority];
                        confirm(`You dropped this ticket (${name_old}) between (${name_below}) and (${name_above}).`)
                        /* TODO: Find a way to choose which priority to assign.
                            Or somehow ask 
                        */
                    }
                }
            }
        },
        create_ticket(title, description, maybe_parent) {
            let ticket = {
                title: title,
                description: description,
                parent: maybe_parent,
                priority: 0, // TODO: Add dropdown for priority.
                type: 0, // TODO: Add dropdown for types.
            };
            const data = { ...ticket };

            // Assign a 'fake' ticket number - our best guess.
            ticket.key = this.likely_next_ticket_number();
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
                        this.tickets[ticket.key] = ticket;
                    }
                    this.max_key = real_key;
                    console.log("create_ticket: success");
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
            this.inset.mode = 'edit';
            this.left_panel.mode = 'edit';
            this.m_et = { ... this.tickets[key], key: key };
            this.m_table.highlight_key = key;
        },
        stop_edit_ticket() {
            if (this.inset.mode === 'edit') this.inset.mode = '';
            if (this.left_panel.mode === 'edit') this.left_panel.mode = '';
            this.m_table.highlight_key = 0;
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
    }));
});