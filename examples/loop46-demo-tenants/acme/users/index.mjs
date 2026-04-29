export function greet(name) {
    return "mjs greet: hello " + (name ?? "world") + " (path=" + request.path + ")\n";
}
export async function slow(delay_label) {
    const v = await Promise.resolve("async " + (delay_label ?? request.path));
    response.status = 202;
    return v + "\n";
}
