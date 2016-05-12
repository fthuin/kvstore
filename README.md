# A biker race project in erlang

This project compiles and runs with the release of erlang named "Erlang R16B03"
and the version of riak named "Riak 2.1.4".

Here are the commands to type to compile and join the nodes from a terminal:

```bash
make
make devrel
for d in dev/dev*; do $d/bin/kvstore start; done
for d in dev/dev*; do $d/bin/kvstore ping; done
./dev/dev2/bin/kvstore-admin join kvstore1@127.0.0.1
./dev/dev3/bin/kvstore-admin join kvstore1@127.0.0.1
...etc
```

In different terminals:

```bash
./dev/dev1/bin/kvstore attach
```

```bash
./dev/dev2/bin/kvstore attach
```

```bash
...etc
```

In each attached console:

```erlang
biker:start_race(UniquePid, NumberOfPlayers).
```

after that, you can follow the instruction for input that will be shown.
