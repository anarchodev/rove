export default function () {
  response.status = 200;
  return {
    user: request.auth.user,          // set by the middleware
    scopes: request.auth.scopes,
    sid: (request.session && request.session.id) || null, // injected
  };
}
