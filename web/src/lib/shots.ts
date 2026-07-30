/**
 * One full-size URL per screenshot, for the lightbox to link at.
 *
 * The `<Picture>` tags on the page top out at 1400 px (plates) and 2048 px
 * (carousel), because that is all a layout slot ever needs. Clicking a shot is
 * the one case that wants the whole thing, so this asks Astro's optimizer for a
 * single transform at the capture's native width — 2880 px windowed, 3420 px
 * fullscreen — in AVIF. Same pixels as the committed PNG, a fraction of the
 * bytes, and still nothing hand-rolled: it is the same pipeline the rest of the
 * page runs through.
 *
 * Note what this deliberately does NOT do: read `.width`, `.height`, or any
 * other field off the imported `ImageMetadata`. Touching one outside a
 * `<Picture>`/`getImage` call makes Astro emit the untouched original next to
 * its transforms — here, 39 MB of PNG on every deploy. Passing the metadata
 * straight into `getImage` is fine; picking it apart is not. (Same reason the
 * `SoftwareApplication` schema in index.astro has no `screenshot` field.)
 */
import { getImage } from "astro:assets";

export async function fullSize(src: ImageMetadata): Promise<string> {
  const image = await getImage({ src, format: "avif", quality: 72 });
  return image.src;
}
