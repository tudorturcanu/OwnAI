# GTC Golden Ticket Contest — Demo Script

Contest: https://developer.nvidia.com/gtc-golden-ticket-contest
Window: **Aug 18 – Sep 10, 2026**. Post a short video on social media, tag the judge
you heard about it from, include **#NVIDIAGTC**. Winners announced ~Sep 14.
Prize: GTC Berlin pass + VIP seating at the keynote (travel not included).

Best-fit judges to tag: **Johnny Nunez** (AI Developer Advocate, NVIDIA) or
**Merve Noyan** (ML Engineer, Hugging Face).

## Setup before filming

- Model: **Nemotron 3 Nano 4B** (downloaded, selected).
- Thinking toggle: **off** for the table/SVG prompts (snappier), optionally **on**
  for one shot to show the reasoning bubble.
- Personality: default system prompt. Code theme: Default (light) or Midnight.
- Charge the phone, enable Do Not Disturb, max screen brightness.

## Video flow (30–45 s, one take)

1. **Airplane mode on** in Control Center — hold the shot for a beat.
2. Open the app, show the Nemotron model card (NVIDIA logo, "runs fully on-device").
3. Prompt 1 — identity beat:
   > What model are you, in one sentence?
4. Prompt 2 — the table (renders as a real formatted table):
   > Plan my 3 days at GTC in Berlin. Reply with only a markdown table with
   > columns Day, Morning, Afternoon, Evening — one row per day, each cell
   > under 8 words. After the table add exactly one sentence of advice.
5. Prompt 3 — the SVG (code block flips into a rendered picture when it finishes).
   Name every element and its color — 4B models compose badly on their own but
   follow an element list well:
   > Draw an SVG of a rocket launching at night. viewBox="0 0 200 300". Include:
   > a full-background dark navy sky rect, a few small white circle stars, a
   > light gray rocket body rectangle in the center, a red triangle nose cone on
   > top, and an orange flame triangle below the rocket. Flat colors only.
   > Reply with only one svg code block.
6. End card / caption for the post:
   > NVIDIA Nemotron 3 Nano 4B running 100% on-device on an iPhone — airplane
   > mode on, zero cloud. It plans, makes tables, and even draws SVGs locally.
   > Built with MLX. @<judge> #NVIDIAGTC

## Backup SVG prompts (retake material — small models vary run to run)

- > Draw an SVG of the Berlin TV tower at dusk. viewBox="0 0 200 300". Include:
  > a full-background dusk-orange sky rect, a tall thin gray rectangle tower in
  > the center, a silver circle sphere near its top, and a dark ground rect at
  > the bottom. Flat colors only. Reply with only one svg code block.
- > Draw an SVG robot face. viewBox="0 0 200 200". Include: a light gray rounded
  > rect head filling most of the canvas, two blue circle eyes, a dark rect
  > smiling mouth, and a line antenna with a red circle tip on top. Flat colors
  > only. Reply with only one svg code block.

Renderer notes: unfenced `<svg>` replies are detected and previewed anyway, and
slightly broken markup (unclosed quotes, `/` instead of `/>`) is auto-repaired
before rendering — so a take is only ruined if the drawing itself is ugly.

## Prompting notes for Nemotron 3 Nano 4B on-device

- Keep instructions short, literal, and single-purpose ("Reply with only …").
- Constrain the SVG: fixed viewBox, whitelist of shapes, flat colors — this is
  what keeps a 4B model's output valid and pretty.
- One task per message; the context budget in-app is ~3,800 tokens.
