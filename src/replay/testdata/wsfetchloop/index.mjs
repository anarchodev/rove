// The agent-loop shape: a held WS conversation that issues an after.fetch
// mid-chain and CONTINUES after the resume. onMessage("start") → fetch(LLM) →
// hold; onResult → write + re-hold (bumping the connection ctx); the page then
// sends the next frame → onMessage again, seeing the resume's ctx + writes.
// Before the fix, the fetch resume was a plain Node, so `.receive(nextFrame)`
// couldn't continue the conversation.
export function onMessage() {
  const turn = request.ctx.turn || 0;
  const msg = browser.message() || {};
  if (msg.t === "start") {
    after.fetch("https://llm.example.com/chat", { ctx: { turn }, on: "onResult" });
    return next({ turn });
  }
  // a follow-up frame, after the fetch resume bumped the ctx
  kv.set("ws/frame2", JSON.stringify({ sawTurn: turn, t: msg.t }));
  stream.write("frame2:turn" + turn);
  return next({ turn });
}

export function onResult() {
  const turn = request.ctx.turn;
  kv.set("ws/llm", JSON.stringify({ turn: turn, ok: request.ok }));
  stream.write("llm-done");
  return next({ turn: turn + 1 }); // bump the connection ctx for the next frame
}
