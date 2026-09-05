# Phase 5 agentic web-build prompts

Three stages, run in sequence against the same agent session. Each is designed
to be completed **one-shot** — the model must not ask the operator questions or
request guidance. `run-web-bench.sh` extracts each stage by its marker and
substitutes:

| Placeholder | Replaced with |
|---|---|
| `{{MODEL_NAME}}` | the run label, e.g. `p5-vk-q4km-mtp` |
| `{{PORT}}` | `4000 + run index`, so every site can be hosted simultaneously |

Edit the prose here, never in the generated per-run copies under `sites/`.

Note: unlike the P100 rig, this is an interactive desktop, not a server
container — no systemd, no elevated privileges. Each stage asks the agent to
run its site as an ordinary background process on its dedicated port, so every
run's site stays browsable side by side after the phase.

<!-- STAGE 1 -->
Create a folder called {{MODEL_NAME}} in the current working directory. Inside it, initialise a Node.js project and build a simple Express website about yourself ({{MODEL_NAME}}). The site should serve a single HTML page on http://localhost:{{PORT}}. Install all dependencies. Start the server as a background process so it keeps running after you finish, and confirm it responds on http://localhost:{{PORT}} before you finish.
<!-- END STAGE 1 -->

<!-- STAGE 2 -->
Restyle the website significantly and go wild with the visual design. Use custom CSS animations, bold colour choices, interesting layout, and whatever flourishes you think suit you as a model. Expand the page content to describe yourself more fully: your architecture, capabilities, context window, intended use cases, and anything else relevant to you as a local LLM. Somewhere on the page, add one small interactive element that demonstrates something about what you can do or how you work — not just a styled button, but something with real behaviour driven by JavaScript. It should be self-contained and feel like a natural part of the page. Use your own judgement about what fits and best shows off your capabilities. When done, restart the background server so the new version is live, and confirm it responds.
<!-- END STAGE 2 -->

<!-- STAGE 3 -->
Add an ice fishing mini-game to the website. Place it directly below the model name heading and above the rest of the page content, as a self-contained <canvas> element of medium size. Write all game logic in a separate file at public/game.js and load it from index.html with a <script src> tag. Make sure Express is configured to serve static files from the public directory.Game mechanics: The hook hangs from the fisher's rod and falls slowly downward by default.While the player holds the mouse button (or touch), the hook reels upward. Releasing causes it to fall again. These two states are mutually exclusive.Fish swim continuously from left to right at varying depths and speeds.If the hook touches a fish, the fish is caught and follows the hook as it is reeled up.If a caught fish reaches the top (the ice layer), it is collected: it disappears, and a visible score counter increments by 1.If no fish is caught, the hook simply stops at the ice when fully reeled and resumes falling on release.Restart the background server so the game is live, and confirm it responds before you finish. You may use emojis in place of the fish, fisher and hook.
<!-- END STAGE 3 -->
