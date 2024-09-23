function display_key(key, max_key) {
    const padding = parseInt(Math.ceil(Math.log10(max_key)));
    return '#' + `${key}`.padStart(padding, '0');
}

document.addEventListener("alpine:init", () => {
    Alpine.data("GOFAST", () => ({
        tickets: {},
        name_priorities: {},
        name_types: {},
        name_statuses: {},

        max_key: 0,

        // Model: The ticket table.
        m_table: {
            highlight_key: 0,
            // page_number: 0,
            // page_from: 0,
            // page_to: 0,
            // max: 1000,
        },
        // Model: New Ticket.
        m_nt: {
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
                this.name_types = r.name_types;
                this.name_priorities = r.name_priorities;
                this.name_statuses = r.name_statuses;
                const keys = r.tickets.keys;
                const parents = r.tickets.parents;
                const titles = r.tickets.titles;
                const descriptions = r.tickets.descriptions;
                const types = r.tickets.types;
                const priorities = r.tickets.priorities;
                const statuses = r.tickets.statuses;

                console.log(`-> /api/tickets -> ${keys.length}/${count} ticket(s), max_key=${max_key}`);

                // const tickets = {};

                this.max_key = max_key;
                for (let i = 0; i < keys.length; ++i) {
                    const key = keys[i];
                    this.tickets[key] = {
                        key: key,
                        title: titles[i],
                        description: descriptions[i],
                        parent: parents[i],
                        type: types[i],
                        priority: priorities[i],
                        status: statuses[i],
                    }
                }
                // this.tickets = tickets;
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

            fetch("/api/tickets", { method: "POST", body: JSON.stringify(data) }).then(async r => {
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
        display_key(key) {
            return display_key(key, this.max_key);
        },
        priority_icon(priority) {
            /*TODO:
                Map priority->image on the server.
            */
            return `/static/ui/icons/priority_${priority - 3}.svg`;
        }
    }));
});