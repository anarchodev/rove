// Reads back the header surface the world build produced: authored names
// arrive in prod's lowercase wire form, request.cookies parses the cookie
// header, and a name prod strips (pseudo / IP-transport / platform-reserved)
// is absent from the surface — not merely unreadable.
export default function () {
  return JSON.stringify({
    ct: request.headers["content-type"],
    names: Object.keys(request.headers),
    sid: request.cookies.sid,
    hasXff: "x-forwarded-for" in request.headers,
    hasRewind: "x-rewind-tenant" in request.headers,
  });
}
