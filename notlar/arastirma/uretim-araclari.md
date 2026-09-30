# Free content-creation toolkit for a Paper 26.2 + Geyser network (research as of 2026-09-29)

**How to read this report:**
- Versions and dates mostly come from GitHub release/commit feeds (`/releases.atom`). These give "updated" timestamps, which can differ from the publish date by a few days.
- The network proxy blocked these sites: modrinth.com, geysermc.org, minecraft.wiki, blockbench.net, axiomdocs.moulberry.com, pepsoft.org, amuletmc.com, gimp.org, inkscape.org, mythiccraft.io and chunky-dev.github.io. Facts about those tools come from search-result snippets and are marked "(snippet)".
- **UNVERIFIED** means I could not confirm it.
- Minecraft context: Java 26.1 came out 2026-03-24 and 26.3 on 2026-09-15. Several tools already target 26.3, one version ahead of your Paper 26.2 ([MC 26.3 news](https://www.minecraft.net/en-us/article/minecraft-java-edition-26-3)).
- **Something I created by mistake:** an aborted `pip download` (meant to check Amulet's license) left one empty directory: `/tmp/claude-0/-home-user-kami/ea35e905-c636-5656-80eb-6d4add6e710b/scratchpad/amulet`. Nothing else was written. You can delete it.

---

## 1. 3D modeling, animation and emotes

| Tool | Role in the pipeline | License / price | Platforms | Latest version (date) | Relevant plugins / addons | Learning curve | Caveats |
|---|---|---|---|---|---|---|---|
| **Blockbench** | Main model, texture and animation editor. Formats: **Java Block/Item** (resource-pack JSON), **Generic Model** (`.bbmodel` for BetterModel / ModelEngine 4), **Bedrock Entity/Block/Item** (for Geyser) | GPL-3.0, free | Windows, macOS, Linux, web app | **5.2.1** (2026-09-21). 5.2.0 "Screen-Space Update" (2026-09-18) added layer groups, a color wheel, IK improvements, a paint bucket in the UV editor and the new Java "Shade Direction Override" cube property | **Animated Java** 1.10.2 (2026-07-07), **GeckoLib** 4.2.5 (for mods only, useless on Paper), **Mesh Tools**, **Texture Stitcher**, **glTF to Minecraft**, **Minecraft Item Wizard** (Bedrock), GeyserModelEngine packer | Low to medium | Java Block/Item models are **cuboids only, no meshes**. The old 22.5° single-axis rotation limit is gone: any angle since 25w16a, multi-axis since 25w46a / 1.21.11. Blockbench issue #3146 is "Done". The −16..32 coordinate bound is UNVERIFIED for 26.x. Large or animated models need a display-entity engine (see next rows) |
| **Animated Java** (Blockbench plugin) | Exports animated rigs as a **datapack + resource pack** using display entities. No server plugin needed | Free and open source (exact license UNVERIFIED) | Blockbench desktop | v1.10.2 (2026-07-07). v1.10.0 (2026-06-23) added "support for Minecraft 26.2 predicate changes" and the 1.21.11 rotation changes, built on Blockbench 5.1.4 | – | Medium to high (needs datapack and function knowledge) | Display entities are not native on Bedrock. Whether GeyserDisplayEntity works with AJ rigs is UNVERIFIED |
| **BetterModel** (server engine for Generic Models) | Runtime engine for Generic `.bbmodel` files: mobs, NPCs, **12-limb player animations (emotes)**, custom hitboxes. Generates the resource pack automatically; no client mod | MIT, free | Paper, Purpur, Folia, Spigot, Leaf, Canvas, Fabric; Java 25 | **3.5.0** (2026-09-20, adds 26.3). 3.2.0 (2026-06-19) added 26.2. README says 1.21.4–26.3.x | Needs no Blockbench plugin | Medium | 3.0.0 added mesh-element conversion (method UNVERIFIED). Bedrock support needs GeyserModelEngine |
| **ModelEngine 4** | Paid alternative to BetterModel | **Paid**. Free trial with a few special models; price UNVERIFIED | Paper | Resource title says 1.19.4–26.2 (snippet) | Ticxo BB plugin | Medium | Not free, so skip it |
| **GeyserModelEngine** + **GeyserDisplayEntity** | Make BetterModel/ModelEngine models and item displays visible to Bedrock players | MIT | Geyser, plus GeyserUtils and Floodgate with `send-floodgate-data` | GME commit "updated to 26.3" (2026-09-26). GDE commits through 2026-08-09, including a 26.2 fix | GME Blockbench packer plugin | Medium | Community projects. Test every model on Bedrock |
| **Emotecraft** | Player emotes. **Players need the client mod**; the Bukkit plugin syncs emotes; a Geyser extension lets Bedrock players see Java emotes | Free | Fabric/NeoForge client; Paper plugin supports 26.2 (snippet) | Active 2026 (snippet) | Authoring in Blockbench needs the GeckoLib Animation Utils plugin plus a template `.bbmodel` | Medium | For server-only emotes (no client mod), BetterModel's player animation is the better fit |
| **Blender** | Concept art, renders, promo cinematics, turntables. **Not** for final Java models | GPL, free | Windows, macOS, Linux | **5.2 LTS** (2026-07-14, supported until July 2028). 5.3 expected 2026-11-10 | **MCprep** 3.6.3 (~2026-07; "Blender 2.83 through 5.2", resources up to 26.2, new JSON-model importer). **Mineways** 14.00 (~2026-09-26/27; exports Java worlds ≤26.3; Windows). **jmc2obj** v128 (2025-10-07; MC 1.21.9; no 26.x release, so reading 26.1+ worlds is UNVERIFIED) | High | Converting a mesh to a Java model is lossy. The [blender-minecraft-json](https://github.com/phonon/blender-minecraft-json) exporter needs 8-vertex, axis-aligned cuboids. The glTF-to-Minecraft plugin replaces "wedges, bevels and rounded shapes" with bounding boxes |

Sources:
- [Blockbench releases](https://github.com/JannisX11/blockbench/releases) · [v5.2.0 notes](https://github.com/JannisX11/blockbench/releases/tag/v5.2.0) · [rotation issue #3146](https://github.com/JannisX11/blockbench/issues/3146) · [BB plugin index](https://github.com/JannisX11/blockbench-plugins/blob/master/plugins.json) · [glTF to Minecraft about](https://github.com/JannisX11/blockbench-plugins/blob/master/plugins/gltf_to_minecraft/about.md)
- [Animated Java](https://github.com/Animated-Java/animated-java) · [AJ v1.10.0](https://github.com/Animated-Java/animated-java/releases/tag/v1.10.0)
- [BetterModel](https://github.com/toxicity188/BetterModel) · [BetterModel releases feed](https://github.com/toxicity188/BetterModel/releases.atom) · [ModelEngine wiki](https://git.mythiccraft.io/mythiccraft/MythicMobs/-/wikis/Model-Engine)
- [GeyserModelEngine](https://github.com/GeyserExtensionists/GeyserModelEngine) · [GeyserDisplayEntity](https://github.com/GeyserExtensionists/GeyserDisplayEntity)
- [Emotecraft](https://emotecraft.org/) · [Emotecraft Blockbench docs](https://docs.zigythebird.com/emotecraft/creatingemotes/blockbench/)
- [Blender 5.2 LTS](https://www.blender.org/press/blender-5-2-lts-release/) · [CG Channel roadmap](https://www.cgchannel.com/2026/02/see-the-2026-blender-development-roadmap/) · [MCprep 3.6.3](https://github.com/Moo-Ack-Productions/MCprep/releases/tag/3.6.3) · [Mineways releases](https://github.com/erich666/Mineways/releases) · [jmc2obj releases](https://github.com/jmc2obj/j-mc-2-obj/releases)

## 2. Pixel art and textures (16x/32x, animated `.mcmeta` strips)

| Tool | License / price | Platforms | Latest (date) | Minecraft fit | Learning curve | Caveats |
|---|---|---|---|---|---|---|
| **Aseprite** | $19.99 for the prebuilt binaries. The source is available, and the EULA allows compiling it "for your own personal purpose". No redistribution. Art you make is yours | Windows, macOS, Linux | **v1.3.18.6** (2026-09-22) | Best in class. Has a vertical-strip sprite-sheet export, and the **Export-Minecraft-Animation (EMA)** script writes `.mcmeta` with tick timing | Low | Building it yourself needs C++, CMake and Skia. Each team member must build their own copy |
| **Pixelorama** | MIT. Free on GitHub, itch.io and web. The paid Steam version is only a donation | Windows, macOS, Linux, **Web**, Android | **v1.2.3** (2026-09-15). v1.2 (~2026-07-29) added a keyframe timeline and autotiling | Timeline, onion skin, sprite-sheet export (set 1 column for a vertical strip), tile mode | Low | You write the `.mcmeta` by hand (it's tiny) |
| **LibreSprite** | GPL-2.0, free | Windows, macOS, Linux, Android | Last release v1.2 (2025-03-06). Commits active in 2026-09 | Aseprite-like interface | Low | Forked from 2016 Aseprite code, so it has fewer features. No 2026 release yet |
| **Krita** | GPL-3.0, free | Windows, macOS, Linux, Android | **5.3.4 / 6.0.4** (2026-09-15). The project recommends 5.3 for production work | Painting, banners, animation timeline | Medium | Sprite-sheet export needs a third-party plugin |
| **GIMP** | GPL-3.0, free | Windows, macOS, Linux | **3.2.6** (2026-09-10) | Retouching, promo compositing | Medium | Clunky for pixel animation |
| **Photopea** | Free with ads. Premium is $5/month or $50/year | Browser | Rolling | Opens PSDs, good for quick edits | Low | Online only; the free tier shows ads |

Blockbench's own paint tools read and write `.png.mcmeta` animated textures (since 4.5), so textures can be painted directly on a model.

Sources:
- [Aseprite releases](https://github.com/aseprite/aseprite/releases) · [Aseprite EULA](https://github.com/aseprite/aseprite/blob/main/EULA.txt) · [Aseprite FAQ](https://www.aseprite.org/faq/) · [EMA script](https://github.com/KuryKat/Export-Minecraft-Animation)
- [Pixelorama](https://github.com/Orama-Interactive/Pixelorama) · [Pixelorama 1.2 blog](https://pixelorama.org/blog/pixelorama-1.2/) · [LibreSprite](https://github.com/LibreSprite/LibreSprite)
- [Krita 5.3.4](https://krita.org/en/posts/2026/krita-5.3.4-released/) · [GIMP 3.2.6](https://www.gimp.org/news/2026/09/10/gimp-3-2-6-released/) · [Photopea pricing](https://costbench.com/software/design/photopea/)

## 3. World building and maps

| Tool | Role | License / price | Latest (date) and 26.2 status | Learning curve | Caveats |
|---|---|---|---|---|---|
| **WorldEdit (Bukkit)** | Standard in-game editing | GPL-3.0, free | **7.4.5** (2026-08-09), for Bukkit 1.21.4–26.2 | Low to medium | – |
| **FAWE** | Faster async WorldEdit for large edits | GPL-3.0, free | **2.15.4** (2026-08-16). 2.15.3 (2026-07-14) "Introduce 26.2 support" | Low to medium | Add-ons: **FastAsyncVoxelSniper** 3.2.5 (2026-08-16) and **WorldEditCUI** (Fabric) 26.2+03 (2026-09-26) |
| **Axiom** | Best-in-class client editor (Fabric) plus a server plugin | Client mod: free **for non-commercial use** only. Paper plugin: MIT | Client 6.0.x for 26.2 (6.0.5 on 2026-09-03, snippet). Paper plugin **6.0.0+26.2** (2026-09-01, snippet) | Medium | **Licensing risk.** Multiplayer use needs a **Commercial License** or a 90-day *non-commercial* whitelist. "If you are making money from your work using Axiom, a Commercial License is required." A network with a store likely counts. Price not public. Singleplayer and localhost are free for non-commercial use |
| **Litematica** | Client-side schematic overlay and planning | LGPL-3.0, free | 26.2-0.28.8 (2026-09-05, snippet); 26.3-0.29.0 (2026-09-22) | Medium | Fabric client mod; works on any server. For `.litematic` to `.schem` use online converters; block entities (chests, signs) are lost |
| **WorldPainter** | Painting large terrain maps (spawn, survival, RPG worlds) | Open source (GPL-3.0 per my recollection, UNVERIFIED), free | **2.27.0** (2026-06-27) supports the 26.1+ map format ("not yet new blocks"). 2.27.1 (2026-08-30; the changelog typo says 2027) | Medium | New 26.x blocks are not in its palette yet |
| **Amulet** | Offline world editor and converter | **No longer free.** Amulet-Core LICENSE: "A licence must be purchased to use this software." The last free version is pre-0.10.45, too old for 26.x | 0.10.64 (2026-09-28) supports Java 26.3 | Medium | **Excluded** under your no-purchase rule |
| **Iris** | Custom world generator | GPL-3.0. Free on GitHub; the Spigot listing is paid as support | **4.1.2** (2026-09-26) for 26.1.2–26.3; 4.1.1 for 26.2; Java 25 | High (JSON packs, studio mode, VS Code) | The release lists 2 assets; that the free GitHub download includes a jar is UNVERIFIED. Pre-generation is heavy |
| **Terra** | Data-driven world generator | MIT (API) + GPL-3.0 (platforms), free | **No 26.x Bukkit release found.** PR #559 (26.1.2–26.3) still open; last master commit 2026-04-28 (1.21.11 mappings) | High | Not usable on Paper 26.2 today (UNVERIFIED whether a dev build exists) |

Sources:
- [WorldEdit releases](https://github.com/EngineHub/WorldEdit/releases) · [WorldEdit 7.4.4 for 1.21.4–26.2](https://dev.bukkit.org/projects/worldedit/files/8366830)
- [FAWE releases](https://github.com/IntellectualSites/FastAsyncWorldEdit/releases) · [FAVS](https://github.com/IntellectualSites/fastasyncvoxelsniper) · [WorldEditCUI](https://github.com/EngineHub/WorldEditCUI/releases)
- [Axiom Paper plugin](https://github.com/Moulberry/AxiomPaperPlugin) · [Axiom commercial license](https://axiom.moulberry.com/commercial) · [Axiom whitelist](https://axiomdocs.moulberry.com/other/whitelist.html)
- [Litematica releases](https://github.com/sakura-ryoko/litematica/releases) · [WorldPainter changelog](https://www.pepsoft.org/worldpainter/CHANGELOG) · [WorldPainter releases](https://github.com/Captain-Chaos/WorldPainter/releases)
- [Amulet](https://github.com/Amulet-Team/Amulet-Map-Editor) · [Amulet-Core license](https://github.com/Amulet-Team/Amulet-Core/blob/2.0/LICENSE)
- [Iris](https://github.com/VolmitSoftware/Iris) · [Terra](https://github.com/PolyhedralDev/Terra) · [Terra PR #559](https://github.com/PolyhedralDev/Terra/pull/559)

## 4. Resource-pack tooling

| Tool | Role | License | Latest (date) | Caveats |
|---|---|---|---|---|
| **PackSquash** | Optimizes and validates packs. Command-line tool plus a GitHub Action | AGPL-3.0 | v0.4.1 (feed date 2026-01-11) | Support for the 1.21.9+ `pack_format` scheme and overlays was committed to master on 2026-08-16 (issue #373 closed), **after** v0.4.1. So 26.x packs probably need an unstable build (UNVERIFIED) |
| **ResourcePackValidator** (MrKinau) | Command-line pack linter plus a GitHub Action | Open source | v2 (2025-02-09) | Coverage of 26.x rules is UNVERIFIED |
| **Minecraft Resourcepack Helper** (VS Code) | Schema validation for models, item definitions, atlases, equipment, fonts and `.mcmeta`; 3D preview | Unlicense | Active repo; version UNVERIFIED | – |
| **Spyglass** (VS Code) | Language server for datapacks | Open source | v2026.9.15 | Mainly for datapacks, not resource packs |
| **misode generators** (web) | Asset generators (`/assets/model`, `/assets/item`, `/assets/blockstate`, `/assets/font`) plus text-component and dialog generators | MIT | Supports 26.1, 26.2, 26.3 | – |
| **MiniMessage viewer** (webui.advntr.dev) | Previews chat, lore, holograms and the server-list MOTD; exports JSON | MIT (PaperMC adventure-webui) | Active | – |
| **GeyserMC Rainbow** | Fabric client mod that generates Geyser mappings plus a Bedrock pack for custom blocks, 2D/3D items, skulls and sounds | GPL-3.0 / LGPL-3.0 | For 26.2; updated 2026-09-15 (snippet) | "Currently experimental" |
| **Thunder / PackConverter** | Converts Java packs that only change vanilla assets | Open source | Work in progress | "Should not be used on production"; does not handle custom items |

Sources:
- [PackSquash](https://github.com/ComunidadAylas/PackSquash) · [PackSquash issue #373](https://github.com/ComunidadAylas/PackSquash/issues/373)
- [RPValidator](https://github.com/MrKinau/ResourcePackValidator) · [RP Helper](https://github.com/stone926/minecraft-resourcepack-helper) · [Spyglass](https://github.com/SpyglassMC/Spyglass)
- [misode](https://misode.github.io/generators/) · [misode item generator](https://misode.github.io/assets/item/) · [MiniMessage viewer](https://webui.advntr.dev/)
- [Rainbow](https://github.com/GeyserMC/Rainbow) · [Thunder](https://geysermc.org/wiki/other/thunder/)

## 5. Promo and visuals

| Tool | Role | License / price | Latest (date) | Caveats |
|---|---|---|---|---|
| **Chunky** | Path-traced stills of your worlds | GPL-3.0, free; needs Java 17 + JavaFX | Stable 2.4.6 (2024-01-14) is too old. Use the **Snapshot** channel: 26.1 world-directory support was merged 2026-03-04, with commits through 2026-09-05 | 26.2/26.3 block coverage is UNVERIFIED |
| **Blender + MCprep + Mineways** | Hero renders, key art, thumbnails | Free | See section 1 | Mineways is Windows-first |
| **Flashback** (Moulberry) | Client-side replay mod for cinematic trailers; works on any server | Custom license, free | 26.3 build around 2026-09-19 (snippet); a 26.2 build is UNVERIFIED | Fabric only |
| **OBS Studio** | Capturing trailers and gameplay | GPL-2.0, free | **32.2.2** (2026-08-14); 33.0 beta since 2026-09-24 | – |
| **Krita / GIMP / Inkscape** | Banners and thumbnails (Krita/GIMP); vector logos (Inkscape) | GPL, free | Inkscape **1.4.4** (2026-05-06, snippet); 1.5 alpha planned for late October 2026 | – |

Sources: [Chunky](https://github.com/chunky-dev/chunky) · [Chunky PR #1870](https://github.com/chunky-dev/chunky/pull/1870) · [Flashback](https://github.com/Moulberry/Flashback) · [OBS releases](https://github.com/obsproject/obs-studio/releases) · [OBS 32.2 notes](https://obsproject.com/blog/obs-studio-32-2-release-notes) · [Inkscape 1.4.4](https://inkscape.org/release/inkscape-1.4.4/)

---

## Recommended free toolkit

1. **3D:** **Blockbench** (Java Block/Item for items and furniture; Generic Model for mobs) with **BetterModel**. BetterModel is free, supports 26.2/26.3, handles emotes without a client mod, and pairs with GeyserModelEngine so Bedrock players see the models. Use Blender only for renders. Skip ModelEngine (paid). Use Animated Java only if you want a datapack-driven setup.
2. **Pixel art:** **Pixelorama**, because it costs nothing, is MIT-licensed, runs in a browser and has a timeline. If one member can compile C++, **Aseprite built from source** is the upgrade (each person compiles their own copy).
3. **Worlds:** **FAWE + WorldEditCUI + FastAsyncVoxelSniper** for building on the server, **WorldPainter** for terrain and **Litematica** for planning. Iris only if you need custom world generation. Avoid **Axiom** on a monetized network unless Moulberry confirms your use is OK, avoid **Amulet** (now paid), and avoid **Terra** (no 26.x build).
4. **Pack pipeline:** **misode** and **VS Code with Resourcepack Helper** for authoring, **PackSquash** (verify 26.x support) for release builds, **Rainbow** for Bedrock mappings, and the **MiniMessage viewer** for text.
5. **Promo:** **Flashback + OBS** for video. **Chunky (Snapshot channel)** or **Blender + Mineways** for stills. **Krita** for banners and **Inkscape** for the logo. Tip: pick fonts (for example Google Fonts under the OFL) that include Turkish glyphs (ğ ş ı İ ç ö ü).

## Suggested learning order for a small team

1. **Weeks 1–2:** resource-pack structure (misode item definitions and models) and Pixelorama for 16x textures and `.mcmeta` strips. Ship a first custom-item pack and test it on Java and on Bedrock via Rainbow.
2. **Weeks 2–3:** Blockbench Java Block/Item for static items and furniture.
3. **Weeks 3–4:** FAWE, WorldEditCUI and FAVS; WorldPainter for the spawn and terrain; Litematica for sharing builds.
4. **Weeks 4–6:** Blockbench Generic Model and animation, loaded into BetterModel (mobs, NPCs, emotes), then made Bedrock-visible with GeyserModelEngine.
5. **Week 6 onward:** promo with Flashback + OBS, Chunky/Blender stills and Krita/Inkscape art. Add PackSquash and a validator to pack releases once the packs stabilize.
