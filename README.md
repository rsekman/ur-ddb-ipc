# DeaDBeeF remote over IPC

A remote for [Unified Remote](https://www.unifiedremote.com/) to control the [DeaDBeeF audio player](https://deadbeef.sf.net) over IPC.

Requires the [`ddb_ipc`](https://github.com/rsekman/ddb_ipc) plugin and suitable configuration.

## Usage

1. Install [`ddb_ipc`](https://github.com/rsekman/ddb_ipc) according to the upstream instructions.
2. Install Unified Remote.
3. Use the Unified Remote server web interface on `localhost:9510` to find where it loads remotes  (default `~/.urserver/remotes/custom` on Arch, ymmv)
4. Clone this repository to the directory containing the remotes (or somewhere else and symlink; I'm not your boss)
5. Use the web interface to reload the list of remotes
6. Open the remote on your other device. It should try to connect automatically when started, and when trying to send a
   command.

IPC requires the server and client to agree on a socket path. The default both here and in `ddb_ipc` is `/tmp/deadbeef-socket`. If you should need to change this, make sure you change both configurations!
