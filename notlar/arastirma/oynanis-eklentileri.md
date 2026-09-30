# Free plugin stack for Paper 26.2 and Velocity 4.2 (research as of 2026-09-29)

**How the data was gathered:** my network blocked Modrinth, Hangar, SpigotMC, dev.bukkit, papermc.io and the essentialsx.net downloads page. Findings come from GitHub pages, GitHub code search and web-search snippets.
- Items marked † come only from a search snippet and were not checked on the page itself.
- GitHub release pages often showed no year. Where the release notes mention 26.x, I took the year to be 2026.
- Anything I could not confirm is marked UNVERIFIED.

Background:
- Java Edition 26.2 ("Chaos Cubed") was released 2026-06-16†. Paper 26.x needs Java 25 (per the WorldGuard notes).
- Velocity 4.0.0 came out 2026-07-14†. 4.2.0 was cut 2026-09-14 ([Velocity#1884](https://github.com/PaperMC/Velocity/issues/1884)). Proxy plugins need to state Velocity 4 support.

## 1. Essentials
| Plugin | License / model | Latest (date) | Paper 26.2 | Velocity | TR | Source | Risk |
|---|---|---|---|---|---|---|---|
| EssentialsX | GPL-3.0, OSS, free | Stable 2.22.0 (2026-05-31). CI build 1829 includes the 26.3 commit | Stable targets "26.1.2" only. The README lists "26.1.2, 26.2, and 26.3", but that support is only in dev builds (commit "Update paperVersion to 26.2…" on 2026-08-05) | backend only | **Yes** (`messages_tr.properties`) | [GitHub](https://github.com/EssentialsX/Essentials), ci.ender.zone | You must run a CI build on 26.2 until the next release |
| HuskHomes | Apache-2.0, free (no paid edition) | 4.11 (14 Aug) | "Added support for Minecraft 26.1.2 and 26.2" | Cross-server through MySQL on the backends | **Yes** (`tr-tr.yml`) | [GitHub](https://github.com/WiIIiam278/HuskHomes) | Only homes, warps and tpa. No kits or economy |

## 2. Region protection
| Plugin | License | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| WorldGuard | GPL-3.0 | 7.0.18 (2026-07-31†). dev.bukkit file title "MC 26.1-26.3"; 7.0.17 was "1.21.11-26.2" | ✔ | No | Nothing earlier than 26.1 works; needs Java 25 |
| WorldEdit | GPL-3.0 | 7.4.4 "Updated to 26.2" (Bukkit file "1.21.4-26.2"). The 7.4.6 changelog says "Update to Minecraft 26.3" | ✔ | UNVERIFIED | Low |
| FAWE | GPL-3.0 | 2.15.4 (16 Aug). 2.15.3 (14 Jul): "Introduce 26.2 support" | ✔ | UNVERIFIED | Replaces WorldEdit; install one or the other, not both |

Sources: [WG changelog](https://github.com/EngineHub/WorldGuard/blob/master/CHANGELOG.md), [WE changelog](https://github.com/EngineHub/WorldEdit/blob/version/7.4.x/CHANGELOG.txt), [FAWE releases](https://github.com/IntellectualSites/FastAsyncWorldEdit/releases)

## 3. Land claims
| Plugin | License / model | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| GriefPrevention | GPL-3.0, free | 16.18.7 (Mar 5; Modrinth tag "1.21.10–26.2"†) | Partial. The commit "Restrict SulfurCube interactions…, update to MC 26.2" (2026-08-28) is **not released yet** | No bundled file (messages are editable) | New 26.2 content isn't trust-protected until the next release |
| HuskClaims | Apache-2.0 source, but "Official binaries and customer support… provided through a paid model" ($12.49 on BuiltByBit†) | GitHub releases stop at 1.5.10 (1.21.6) | UNVERIFIED | — | **Not free** unless you compile it yourself |
| Lands | Paid (not re-checked) | — | — | — | Excluded |

Sources: [GP commits](https://github.com/GriefPrevention/GriefPrevention/commits/master), [HuskClaims](https://github.com/WiIIiam278/HuskClaims)

## 4. Block logging
| Plugin | License / model | Paid edition adds | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|---|
| CoreProtect CE | Artistic-2.0. Community Edition is free on SpigotMC and Hangar, and via a public Patreon post (the GitHub release has no jar) | Patreon "early access to builds with exclusive functionality" | CE v24.1 (2026-09-24): "Added support for Minecraft 26.2" | ✔ | **Yes** (`lang/tr.yml`) | The free CE lags behind: 26.2 support arrived about 3 months after 26.2 |
| Prism 4 | MIT | — | v4.4 (7 Jul): "26.2 Support" | ✔ (Paper 1.21.4+) | UNVERIFIED | Smaller community |

Sources: [CoreProtect v24.1](https://github.com/PlayPro/CoreProtect/releases/tag/v24.1), [Prism](https://github.com/prism/Prism/releases)

## 5. Economy API
| Plugin | License | Latest | 26.2 | Note |
|---|---|---|---|---|
| VaultUnlocked | LGPL-3.0+ | 2.20.1 (16 Jun): "Added support for 26.2". SpigotMC shows 2.20.3† (date UNVERIFIED) | ✔ | It is only the API. You still need an economy provider, e.g. EssentialsX Economy. [GitHub](https://github.com/TheNewEconomy/VaultUnlocked/releases) |

## 6. Player shops
| Plugin | License | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| QuickShop-Hikari | GPLv3 + AGPLv3 (dual) | 6.3.0.3 (2026-09-23): "Added support for 26.3" | Implied. No explicit 26.2 changelog line (UNVERIFIED) | **Yes** (Crowdin `tr-TR`) | Heavy on resources. [GitHub](https://github.com/QuickShop-Community/QuickShop-Hikari/releases) |
| ChestShop-3 | LGPL-2.1 | 3.13-pre-1 (15 Jul): "tested with 1.13-26.2" | ✔ (pre-release) | Not found | Pre-release only. [GitHub](https://github.com/ChestShop-authors/ChestShop-3/releases) |
| Shopkeepers | UNVERIFIED | 2.27.0† (2026-09-26†), MC 26.2† | ✔† | UNVERIFIED | Villager shops; can also be used for admin shops |

## 7. Server shop GUI
| Plugin | License / model | Premium adds | Latest | 26.2 | Risk |
|---|---|---|---|---|---|
| EconomyShopGUI (free edition) | CurseForge lists LGPLv3†, but I found no public source, so treat it as free closed-source | GUI editor, dynamic pricing, stock limits, PlaceholderAPI, MySQL sync, command/NBT items ([wiki](https://wiki.gpplugins.com/economyshopgui)) | v7.1.0† (2026-06-20) added 26.2; 7.2.x† in Aug 2026 | ✔† | Closed source |
| zShop / ExcellentShop | Paid (zShop: [GitHub](https://github.com/Maxlego08/zShop) says to buy on SpigotMC). ExcellentShop official builds only go up to 1.21.11 | — | — | — | Excluded |

## 8. Auction house
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| AuctionHouse (ElaineQheart) | GPL-3.0 | 1.5.5† (2026-09-06†, "1.21-26.2"). The repo's `plugin.yml` is already at 1.5.6 | ✔† | One developer; storage/MySQL not verified. [GitHub](https://github.com/ElaineQheart/Auction-House) |
| CrazyAuctions | MIT | 1.7.0 (7 Jan), tagged up to 26.1.2† | UNVERIFIED | The README says only the newest Minecraft version is supported |
| zAuctionHouse / AxAuctions | Paid (€12† / BuiltByBit†) | — | — | Excluded |

## 9. Menus
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| zMenu | GPL-3.0, free | The Paper 26.2 PR was merged 2026-09-14 ([#268](https://github.com/Maxlego08/zMenu/pull/268)). The 1.1.1.4 release added "full Bedrock inventory support via Geyser/Floodgate". Newest version number UNVERIFIED | ✔ (merged; release UNVERIFIED) | Can read DeluxeMenus config files |
| DeluxeMenus | MIT | 1.14.1† (2025-08-13, "1.16–1.21.11"). Last commit 2026-09-29 | UNVERIFIED (only CI dev builds) | No release that targets 26.x |

## 10. Holograms
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| DecentHolograms | GPL-3.0 | 2.10.1 (28 Jun): "Added support for Minecraft 26.2 (v26_2)" | ✔ | Custom item NBT may not work on 26.2 (item-nbt-api not updated yet)† |
| FancyHolograms | MIT | 2.12.0† (2026-09-15) | ✔† (listing says "1.21.5 through 26.2") | Its FancyNpcs integration breaks on 26.3 ([#337](https://github.com/FancyInnovations/FancyPlugins/issues/337)) |

## 11. NPCs
| Plugin | License / model | Latest | 26.2 | Risk |
|---|---|---|---|---|
| FancyNpcs | MIT | 2.11.0+369†: "1.21.5–1.21.11, 26.1.2–26.2". 2.12.0 also exists | ✔ | 2.12.0 fails to enable on 26.3 (#336) |
| ZNPCsPlus | GPL-3.0 | Commit "added 26.2 support" (2026-07-01). The README says "Minecraft 1.8 - 26.2". Last formal release is 2.0.0 | ✔ only in Jenkins dev builds (ci.pyr.lol) | No current stable release |
| Citizens | OSL-3.0. SpigotMC listing is paid; identical builds are free on Jenkins | Spigot "2.0.43 (26.2 BUILD #2)"†; Jenkins v26_2_R1 build #4256 | ✔ | Heavy; you have to download from Jenkins |

## 12. Tab list / scoreboard
| Plugin | License / model | Latest | 26.2 | Velocity | TR | Risk |
|---|---|---|---|---|---|---|
| TAB (NEZNAMY) | Apache-2.0. Free on GitHub, Modrinth, SpigotMC and CurseForge. The BuiltByBit listing is paid (same plugin) | 6.2.0 (17 Sep): "Added 26.3 Bukkit support" | ✔ (wiki: latest supported is 26.2†) | Supported. On the proxy, scoreboard/nametag features need VelocityScoreboardAPI. Velocity 4: UNVERIFIED | No bundled translations (all text is set in config) | Safer installed on the backends. [GitHub](https://github.com/NEZNAMY/TAB) |

## 13. Chat formatting and moderation
| Plugin | License | Latest | 26.2 | Velocity | TR | Risk |
|---|---|---|---|---|---|---|
| CarbonChat | GPL-3.0 | v3.0.0-beta.39 (18 Sep): "compatible with 26.2 and 26.3" | ✔ | Has a Velocity build (beta.37 moved to Velocity 3.5). Velocity 4: UNVERIFIED | Only en_US in the repo; Crowdin Turkish UNVERIFIED | Still labelled "beta". [GitHub](https://github.com/Hexaoxide/Carbon/releases) |
| ChatSentinel (anti-swear/spam) | GPL-3.0 | 2.0.3 commit (2026-08-04) | UNVERIFIED | Spigot, Bungee and Velocity | — | You may need to build it yourself. [GitHub](https://github.com/2lstudios-mc/ChatSentinel) |

## 14. Punishments
| Plugin | License | Latest | 26.2 | Velocity | TR | Risk |
|---|---|---|---|---|---|---|
| LibertyBans | AGPL-3.0 (API under LGPL) | 1.1.4 (4 Jul): "Added compatibility with Paper 26.2". 1.2.0-M1 (21 Sep) is a milestone: "Add support for Velocity 4" | ✔ | **Only the 1.2.0-M1 milestone supports Velocity 4.** Mutes on the proxy need SignedVelocity† | **Yes** (`messages_tr.yml`) | Running on Velocity 4.2 means using a pre-release. [Releases](https://github.com/A248/LibertyBans/releases) |

## 15. Anti-cheat
| Plugin | License | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| GrimAC | GPL-3.0 | README: "Minecraft versions 1.8–26.3". Commit "support 26.3" on 2026-09-28. Modrinth 2.3.74† (2026-06-10) was tagged 1.7.2–26.1.2 | ✔ per README; exact release build UNVERIFIED | **Yes** (`messages/tr.yml`) | Needs Floodgate on the backends so Bedrock players are exempted. [GitHub](https://github.com/GrimAnticheat/Grim) |

## 16. Web map
| Plugin | License | Latest | 26.2 | TR |
|---|---|---|---|---|
| BlueMap | MIT | 5.28 (25 Sep): "Paper/Folia 26.1.1 - 26.3" | ✔ | **Yes** (web app `tr.conf`). [Releases](https://github.com/BlueMap-Minecraft/BlueMap/releases) |

## 17. Votes
| Plugin | License | Latest | 26.2 / Velocity 4 | Risk |
|---|---|---|---|---|
| NuVotifier | GPL-3.0 | 2.7.3 (notes: "compatible with Velocity 3.0.0"), no newer release | UNVERIFIED on both | Effectively unmaintained |
| VotifierPlus | — | 1.4.2 (last update 2025-08-03†) | UNVERIFIED | Only small maintenance updates |
| azuvotifier | — | 3.4.0-beta.0 (2026-01†, Velocity API 3.4) | UNVERIFIED | Beta |
| VotingPlugin | CC BY 3.0 (LICENSE.md), free | 7.1.1 (23 Jul). Active PRs 2026-09-26 | Explicit 26.2 support UNVERIFIED. Supports proxy setups | No Turkish |

Sources: [NuVotifier](https://github.com/NuVotifier/NuVotifier/releases), [VotingPlugin](https://github.com/BenCodez/VotingPlugin/releases)

## 18. Discord bridge
| Plugin | License | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| DiscordSRV 1.x | GPL-3.0 | 1.30.5 (24 Apr): "NMS issue with GameProfiles on MC 26.x" | Says "26.x"; 26.2 specifically UNVERIFIED | **No** (14 languages, no Turkish) | v3 "Ascension" is only testing builds on their Discord. [Release](https://github.com/DiscordSRV/DiscordSRV/releases/tag/v1.30.5) |

## 19. Skins for cracked players
| Plugin | License | Latest | 26.2 | Velocity | TR |
|---|---|---|---|---|---|
| SkinsRestorer | GPL-3.0 | 15.12.6 (20 Sep): "support Minecraft 26.3". 15.12.4 (28 Jun): "update target to 26.2" | ✔ | ✔ (15.12.4 moved to velocity-api v4) | **Yes** (`locale_tr.json`). [Releases](https://github.com/SkinsRestorer/SkinsRestorer/releases) |

## 20. Placeholders
| Plugin | License | Latest | 26.2 | Velocity |
|---|---|---|---|---|
| PlaceholderAPI | GPL-3.0 | 2.12.3 (3 Jul): works on 26.2, but "experimental on Paper" | ⚠ experimental | — |
| MiniPlaceholders | Apache-2.0 | 3.2.1 (2026-09-07). velocity-api v4 bump on 2026-08-27 | ✔ | ✔ |

## 21. Crates
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| CrazyCrates | MIT | 5.2.0 (18 Jul). Hangar builds for 26.1.2–26.2 through 2026-09-28† | ✔† (needs Paper 26.x and Java 25) | No Turkish |
| ExcellentCrates | GPL-3.0, free | 6.6.1† (2025-12-13, Paper 1.21.8–1.21.11) | Only through a third-party fork, [ExcellentCrates-Continued](https://github.com/glsoo/ExcellentCrates-Continued) | The official plugin has no 26.x build |

## 22. Quests
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| BetonQuest | GPL-3.0 | 3.2.0 (17 Aug): fixes for "MC 26.2+" | ✔ | Steep learning curve; Turkish UNVERIFIED |
| Quests (PikaMug) | UNVERIFIED | 5.3.2 (3 Aug). 5.2.9 was "tested working with Minecraft 26.1" | UNVERIFIED | — |

## 23. Jobs and skills
| Plugin | License | Latest | 26.2 | TR | Risk |
|---|---|---|---|---|---|
| AuraSkills | GPL-3.0 | 2.4.0 (20 Sep): "Minecraft 26.3 support". 2.3.12: "Paper 26.1.1" | ✔† | **Yes** (`messages_tr.yml`) | Low |
| Jobs Reborn | Apache-2.0 / GPL-3.0 | 5.2.6.6† (SpigotMC, around Jul 2026) | UNVERIFIED | **Yes** (`messages_tr.yml`) | Needs CMILib (free but closed source) |

## 24. Lobby utilities
| Plugin | License | Latest | 26.2 / Velocity | Note |
|---|---|---|---|---|
| Hubbly | AGPL-3.0 | 3.6.2† (2026-07-07, "26.1 and 26.2") | ✔† | Compass server selector, anti-void-fall, double jump. [GitHub](https://github.com/CalRL/Hubbly) |
| DeluxeHub | UNVERIFIED | 3.8.2† (2026-07-27, 26.2) | ✔† | Maintainer and license unclear |
| velocity-hub-command (/hub, /lobby) | UNVERIFIED | 1.10-SNAPSHOT† (2026-08-07), built against Velocity 4.1.0-SNAPSHOT, Java 25 | Velocity 4 ✔† | Snapshot releases only. [GitHub](https://github.com/stellarcielo/velocity-hub) |
| HUB (uebliche) | — | GitHub repo now returns 404 | — | Avoid |

## 25. ChunkyBorder
| Plugin | License | Latest | 26.2 | Risk |
|---|---|---|---|---|
| ChunkyBorder | GPL-3.0 | 1.2.23 (SpigotMC). Last commit 2025-09-04. In PR #118 (Sep 2026) the maintainer said they are "still targeting Minecraft 1.21.x" | UNVERIFIED | Possibly stale. The vanilla `/worldborder` command is a zero-risk alternative |

---

## Recommended free stack (one pick per category)
1. **Essentials: EssentialsX CI build.** It has Turkish, kits, spawn, and can act as the Vault economy. Until 2.23 ships, 26.2 support is only in CI builds. If you won't run a dev build, use **HuskHomes** instead.
2. **Region protection: WorldGuard 7.0.18 + WorldEdit 7.4.4 or newer.** Both are EngineHub's own matched releases. Swap in FAWE only if you do very large edits.
3. **Land claims: GriefPrevention.** It is the only mature free choice. Watch for the release that includes the 26.2 sulfur-cube trust fix.
4. **Block logging: CoreProtect CE v24.1.** It has Turkish and is the de facto standard.
5. **Economy API: VaultUnlocked**, with EssentialsX Economy as the provider.
6. **Player shops: QuickShop-Hikari.** It is open source, has Turkish, and is updated often.
7. **Server shop: EconomyShopGUI free edition.** The fallback is a shop built in zMenu.
8. **Auction house: AuctionHouse (ElaineQheart).** It is the only open-source one tagged for 26.2. Test it before going live.
9. **Menus: zMenu.** It is GPL, has Paper 26.2 support merged, and shows Bedrock forms through Geyser/Floodgate, which matters for your Bedrock players.
10. **Holograms: DecentHolograms 2.10.1.** It explicitly supports 26.2 and needs no other plugins.
11. **NPCs: FancyNpcs 2.11.0.** Its release explicitly covers 26.2. The fallback is Citizens from Jenkins.
12. **Tab/scoreboard: TAB 6.2.0 on each Paper backend.** This avoids the unverified Velocity 4 and VelocityScoreboardAPI path.
13. **Chat: CarbonChat on the backends**, plus ChatSentinel if you want a swear filter.
14. **Punishments: LibertyBans.** Stable option: 1.1.4 on both backends with a shared MariaDB. Pre-release option: 1.2.0-M1 plus SignedVelocity on the proxy.
15. **Anti-cheat: GrimAC.** Use the newest build, and keep Floodgate on the backends so Bedrock players are exempted.
16. **Web map: BlueMap 5.28.**
17. **Votes: NuVotifier + VotingPlugin, both on the survival backend only.** Open just the votifier port to the internet. This avoids the Velocity 4 question, but test first; NuVotifier is unmaintained.
18. **Discord: DiscordSRV 1.30.5.** It is the only real free option; test it on 26.2 first.
19. **Skins: SkinsRestorer 15.12.6.** It supports both 26.2 and Velocity 4.
20. **Placeholders: PlaceholderAPI** on the backends (26.2 is "experimental") and **MiniPlaceholders** on Velocity.
21. **Crates: CrazyCrates.**
22. **Quests: BetonQuest 3.2.0.**
23. **Jobs/skills: AuraSkills.** It is open source, has Turkish, and explicitly supports 26.x. Add Jobs Reborn (needs CMILib) only if you want a jobs-based economy.
24. **Lobby: Hubbly** (void teleport, selector, double jump) plus **velocity-hub-command** for `/hub`.
25. **World border: vanilla `/worldborder`**, or ChunkyBorder 1.2.23 after testing on a staging server.

**Biggest risks:**
- These run on dev or pre-release builds: EssentialsX (CI builds), LibertyBans on Velocity 4 (1.2.0-M1 milestone), ZNPCsPlus (Jenkins dev builds).
- These may be stale: NuVotifier, ChunkyBorder, DeluxeMenus, GriefPrevention's 26.2 fix (unreleased).
- These are paid and should be avoided: HuskClaims, Lands, zAuctionHouse, AxAuctions, zShop.
