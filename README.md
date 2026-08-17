# Roze
Silver Palace Server Emulator prioritizing performance, stability and correctness.

![screenshot](assets/images/screenshot.png)

## Architecture
- **Static memory allocation.** `Roze` doesn't make heap allocations after startup. Instead, during the initialization, it allocates all of the required resources up-front, based on CLI arguments. This allows for predictable resource consumption. Once the server is started up, the memory footprint won't grow. Therefore it's trivial for server operators to put hard resource limits without using complicated and vendor-specific features like cgroups for this.
- **Asynchronous I/O.** The server uses the state-of-the-art I/O primitives, such as `io_uring`. We're not relying on "language magic" (such as async/await) to make use of it. Instead, we implement a crossplatform wrapper providing completion-based I/O interface. It's the application's responsibility to implement an event loop itself on top of it. We're writing state machines by hand. **Why `async`/`await` when you can `switch`?**
- **No external dependencies.** Focusing on performance, it's important to have every component of the software purpose-built. This allows not wasting any performance doing unnecessary work. For example, a general-purpose protobuf deserialization library, by the spec, would not allow zero-allocation decoding. However, knowing the end implementation that is on the client we're building the server for, instead of thinking of some possible "abstract" implementation that does not exist, we can optimize **the spec itself** for our concrete use-case.

## Platform support
Because we maintain our own I/O layer, platform support depends on the existence of an implementation of this layer for the target.

At present, we support `Linux` and `Windows`.

##### NOTE: on Linux, you **must** have `io_uring` enabled.

## Requirements
**Roze** is a zero-dependency project from day one, all you need to build it from sources is:
- Zig Compiler, version `0.17.0-dev.1778+767d25269`: [Linux](https://ziglang.org/builds/zig-x86_64-linux-0.17.0-dev.1778+767d25269.tar.xz)/[Windows](https://ziglang.org/builds/zig-x86_64-windows-0.17.0-dev.1778+767d25269.zip)

##### HINT: if you're using Linux, you can run the `envrc` script included in this repository to setup the zig environment. It's a simple `/bin/sh` script that downloads zig compiler, untars it and adds to the `$PATH`.

## Compiling and running
Once you've got `zig` compiler set up, you can compile the server.
First, double-check that the compiler version matches by typing `zig version` in your terminal.
```sh
$ zig version
0.17.0-dev.1778+767d25269
```
If the output matches, you can proceed to the compilation.

Start by cloning the repository using [git](https://git-scm.com/).
```sh
$ git clone https://git.xeondev.com/roze/roze.git
```

In short, to **compile** the server, a single command is enough:
```sh
$ zig build
```
That's it. The resulting binaries will appear under the `zig-out/bin/` directory.

However, if you want to compile **and run** it, you have to run three commands (one command per service).

Note that they have to be kept running.
```sh
zig build run-dir-server
zig build run-sdk-server
zig build run-scene-server
```

Optionally, if you run the server locally and are the only person who will be using it, you can pass the `--concurrency 1` argument to each service. This will make the server allocate memory for one session only, instead of the default value that is a bit higher. Example for `scene-server`:
```sh
$ zig build run-scene-server -- --concurrency 1
```

If you've got all three servers running (each one should log out the fact that it's waiting), you can proceed to the client setup.

## Client setup
Follow the instructions in the [Bloom Repository](https://git.xeondev.com/roze/bloom).

## Strict No LLM / No AI Policy
Use of generative AI/LLMs is strictly forbidden for all contributions to **roze**.

This includes conversations in our discord server.

## Contributing
[Donate](https://boosty.to/xeondev/donate).

[Join project-specific discord server](https://red-rose.xeondev.com).

[Join ReversedRooms discord server](https://discord.xeondev.com).

[Join ReversedRooms telegram channel](https://t.me/reversedrooms).

The contributions (in form of patches) can be submitted in one of our discord servers. You can also get an account on [our git instance](https://git.xeondev.com/) after a number of accepted contributions.

## License
This repository was made public in the hopes that it will be useful. However, it comes with no warranty whatsoever (expressed or implied).
It's licensed under [GNU Affero General Public License v3](LICENSE).
