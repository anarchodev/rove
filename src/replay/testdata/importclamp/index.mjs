// Over-popped ../ must clamp to the app root, not escape source_dir.
import { tag } from "../../../rootshared.mjs";
export default function () { return { tag }; }
