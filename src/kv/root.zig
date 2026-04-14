//! rove-kv: KV store + raft, layered on rove-io.

const kvstore = @import("kvstore.zig");
const raft_log = @import("raft_log.zig");
pub const raft_rpc = @import("raft_rpc.zig");
pub const raft_net = @import("raft_net.zig");
pub const raft_node = @import("raft_node.zig");
const writeset_mod = @import("writeset.zig");

pub const RaftNet = raft_net.RaftNet;
pub const RaftNetConfig = raft_net.RaftNet.Config;
pub const RaftPeerAddr = raft_net.PeerAddr;
pub const RaftRecvFn = raft_net.RecvFn;

pub const RaftNode = raft_node.RaftNode;
pub const RaftNodeConfig = raft_node.Config;
pub const RaftApplyMode = raft_node.ApplyMode;
pub const RaftApplyFn = raft_node.ApplyFn;

pub const WriteSet = writeset_mod.WriteSet;
pub const WriteSetOp = writeset_mod.Op;
pub const applyEncodedWriteSet = writeset_mod.applyEncoded;

pub const KvStore = kvstore.KvStore;
pub const KvEntry = kvstore.Entry;
pub const KvDeltaEntry = kvstore.DeltaEntry;
pub const KvRangeResult = kvstore.RangeResult;
pub const KvDeltaResult = kvstore.DeltaResult;
pub const KvError = kvstore.Error;
pub const TrackedTxn = kvstore.KvStore.TrackedTxn;

pub const RaftLog = raft_log.RaftLog;
pub const RaftLogEntry = raft_log.Entry;
pub const RaftPersistentState = raft_log.PersistentState;
pub const RaftLogError = raft_log.Error;

test {
    _ = kvstore;
    _ = raft_log;
    _ = raft_rpc;
    _ = raft_net;
    _ = raft_node;
    _ = writeset_mod;
}
