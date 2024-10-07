# GOFAST
![logo](https://github.com/BraynStorm/gofast/blob/master/static/ui/icons/priority_-4.svg?raw=true)
![logo](https://github.com/BraynStorm/gofast/blob/master/static/ui/icons/favicon.svg?raw=true)
![logo](https://github.com/BraynStorm/gofast/blob/master/static/ui/icons/priority_-4.svg?raw=true)

_Tickets gotta GoF..._

Ticket system for keeping track of tasks.


## Running
Requires Zig 0.13.0.


Compile the scss to css:

```bash
sass static static
```

Run with (for a release build, append `--release=small` at the end):

```bash
zig build run
```

## TODO
- A good README.md
- Card view drag&drop
- Authentication system
- Good graph view of ticket time left.

- Extra Side Projects
    - Add build system
        - With workers, distributed, like Jenkins
    - Add source control view (Git)
