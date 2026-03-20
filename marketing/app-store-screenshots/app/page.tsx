"use client";

import { toPng } from "html-to-image";
import { useEffect, useMemo, useRef, useState } from "react";

const CANVAS_W = 1320;
const CANVAS_H = 2868;
const PREVIEW_W = 320;
const PREVIEW_H = (PREVIEW_W / CANVAS_W) * CANVAS_H;

const IPHONE_SIZES = [
  { label: '6.9"', w: 1320, h: 2868 },
  { label: '6.5"', w: 1284, h: 2778 },
  { label: '6.3"', w: 1206, h: 2622 },
  { label: '6.1"', w: 1179, h: 2556 },
] as const;

type SizeOption = (typeof IPHONE_SIZES)[number];
type ThemeId = "sunrise-private" | "midnight-glow" | "paper-signal";
type SlideId =
  | "hero"
  | "local"
  | "docs"
  | "control";

type Theme = {
  id: ThemeId;
  name: string;
  bg: string;
  bg2: string;
  panel: string;
  ink: string;
  muted: string;
  accent: string;
  accent2: string;
  card: string;
  shadow: string;
};

type Slide = {
  id: SlideId;
  label: string;
  eyebrow: string;
  headline: string[];
  subhead: string;
  screenshot: string;
};

const THEMES: Record<ThemeId, Theme> = {
  "sunrise-private": {
    id: "sunrise-private",
    name: "Sunrise Private",
    bg: "#fff5e7",
    bg2: "#ffe2d0",
    panel: "#fffaf4",
    ink: "#1f2430",
    muted: "#6f6a63",
    accent: "#ff7a45",
    accent2: "#ff4d8d",
    card: "rgba(255,255,255,0.72)",
    shadow: "rgba(200,96,52,0.24)",
  },
  "midnight-glow": {
    id: "midnight-glow",
    name: "Midnight Glow",
    bg: "#0f172a",
    bg2: "#1e293b",
    panel: "#101826",
    ink: "#f8fafc",
    muted: "#b9c4d4",
    accent: "#5eead4",
    accent2: "#60a5fa",
    card: "rgba(15,23,42,0.72)",
    shadow: "rgba(15,23,42,0.44)",
  },
  "paper-signal": {
    id: "paper-signal",
    name: "Paper Signal",
    bg: "#f4efe7",
    bg2: "#dfe7f5",
    panel: "#fcfaf7",
    ink: "#231f20",
    muted: "#625c59",
    accent: "#2563eb",
    accent2: "#f97316",
    card: "rgba(252,250,247,0.78)",
    shadow: "rgba(37,99,235,0.16)",
  },
};

const SLIDES: Slide[] = [
  {
    id: "hero",
    label: "01",
    eyebrow: "Private AI",
    headline: ["Private AI", "on your iPhone"],
    subhead:
      "Local models, calm design, and Apple Intelligence support when you choose it.",
    screenshot: "/screenshots/01-hero.png",
  },
  {
    id: "local",
    label: "02",
    eyebrow: "Local Chat",
    headline: ["Chat with", "local models"],
    subhead:
      "Pick the engine that fits your device and keep fast replies close to home.",
    screenshot: "/screenshots/02-local-models.png",
  },
  {
    id: "docs",
    label: "03",
    eyebrow: "Document Q&A",
    headline: ["Ask questions", "about PDFs"],
    subhead:
      "Import docs, pull the right context, and turn long files into clear answers.",
    screenshot: "/screenshots/03-docs.png",
  },
  {
    id: "control",
    label: "04",
    eyebrow: "Trust Signal",
    headline: ["Keep chats", "under your control"],
    subhead:
      "Stored locally, privacy explained up front, and built for people who want more control.",
    screenshot: "/screenshots/04-privacy.png",
  },
];

const MK_W = 1022;
const MK_H = 2082;
const SC_L = (52 / MK_W) * 100;
const SC_T = (46 / MK_H) * 100;
const SC_W = (918 / MK_W) * 100;
const SC_H = (1990 / MK_H) * 100;
const SC_RX = (126 / 918) * 100;
const SC_RY = (126 / 1990) * 100;

function rgba(hex: string, alpha: number) {
  const clean = hex.replace("#", "");
  const value = clean.length === 3
    ? clean
        .split("")
        .map((part) => part + part)
        .join("")
    : clean;
  const int = Number.parseInt(value, 16);
  const r = (int >> 16) & 255;
  const g = (int >> 8) & 255;
  const b = int & 255;
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

function ControlChip({
  active,
  children,
  onClick,
}: {
  active: boolean;
  children: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      style={{
        border: "none",
        padding: "10px 14px",
        borderRadius: 999,
        background: active ? "#1f2937" : "rgba(255,255,255,0.7)",
        color: active ? "white" : "#334155",
        fontWeight: 600,
        cursor: "pointer",
      }}
    >
      {children}
    </button>
  );
}

function PhoneFrame({
  children,
  style,
}: {
  children: React.ReactNode;
  style?: React.CSSProperties;
}) {
  return (
    <div
      style={{
        position: "relative",
        aspectRatio: `${MK_W}/${MK_H}`,
        width: "100%",
        ...style,
      }}
    >
      <img
        src="/mockup.png"
        alt=""
        draggable={false}
        style={{ display: "block", width: "100%", height: "100%" }}
      />
      <div
        style={{
          position: "absolute",
          zIndex: 2,
          overflow: "hidden",
          left: `${SC_L}%`,
          top: `${SC_T}%`,
          width: `${SC_W}%`,
          height: `${SC_H}%`,
          borderRadius: `${SC_RX}% / ${SC_RY}%`,
          background: "#f6f2ec",
        }}
      >
        {children}
      </div>
    </div>
  );
}

function AppHeader({ theme, title }: { theme: Theme; title: string }) {
  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        padding: "34px 34px 22px",
      }}
    >
      <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
        <div
          style={{
            width: 54,
            height: 54,
            borderRadius: 18,
            background: `linear-gradient(135deg, ${theme.accent}, ${theme.accent2})`,
            boxShadow: `0 20px 40px ${rgba(theme.accent2, 0.25)}`,
          }}
        />
        <div>
          <div style={{ fontSize: 14, color: theme.muted, letterSpacing: 1.6 }}>
            OWN AI
          </div>
          <div style={{ fontSize: 24, fontWeight: 700, color: theme.ink }}>{title}</div>
        </div>
      </div>
      <div
        style={{
          width: 36,
          height: 36,
          borderRadius: 18,
          background: rgba(theme.ink, 0.08),
        }}
      />
    </div>
  );
}

function ScreenShell({
  theme,
  children,
}: {
  theme: Theme;
  children: React.ReactNode;
}) {
  return (
    <div
      style={{
        width: "100%",
        height: "100%",
        background: `linear-gradient(180deg, ${rgba(theme.accent, 0.12)} 0%, ${rgba(
          theme.accent2,
          0.08,
        )} 46%, #fff 100%)`,
      }}
    >
      {children}
    </div>
  );
}

function ChatBubble({
  theme,
  align = "left",
  title,
  lines,
}: {
  theme: Theme;
  align?: "left" | "right";
  title?: string;
  lines: string[];
}) {
  const isRight = align === "right";
  return (
    <div
      style={{
        alignSelf: isRight ? "flex-end" : "flex-start",
        maxWidth: "78%",
        borderRadius: isRight ? "28px 28px 10px 28px" : "28px 28px 28px 10px",
        background: isRight
          ? `linear-gradient(135deg, ${theme.accent}, ${theme.accent2})`
          : "rgba(255,255,255,0.9)",
        color: isRight ? "white" : theme.ink,
        padding: "20px 22px",
        boxShadow: `0 16px 36px ${rgba(theme.ink, 0.08)}`,
      }}
    >
      {title ? (
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 8, opacity: 0.72 }}>{title}</div>
      ) : null}
      {lines.map((line) => (
        <div key={line} style={{ fontSize: 24, lineHeight: 1.25, fontWeight: 600 }}>
          {line}
        </div>
      ))}
    </div>
  );
}

function StatCard({
  theme,
  title,
  value,
}: {
  theme: Theme;
  title: string;
  value: string;
}) {
  return (
    <div
      style={{
        flex: 1,
        padding: "20px 18px",
        background: "rgba(255,255,255,0.92)",
        borderRadius: 28,
        boxShadow: `0 20px 40px ${rgba(theme.ink, 0.08)}`,
      }}
    >
      <div style={{ fontSize: 14, letterSpacing: 1.4, color: theme.muted }}>{title}</div>
      <div style={{ fontSize: 30, fontWeight: 800, color: theme.ink, marginTop: 8 }}>{value}</div>
    </div>
  );
}

function MockScreen({ slide, theme }: { slide: SlideId; theme: Theme }) {
  if (slide === "hero") {
    return (
      <ScreenShell theme={theme}>
        <AppHeader theme={theme} title="Private chat" />
        <div style={{ padding: "0 28px", display: "flex", gap: 16 }}>
          <StatCard theme={theme} title="MODE" value="On-device" />
          <StatCard theme={theme} title="VOICE" value="Ready" />
        </div>
        <div style={{ padding: "24px 28px 0", display: "flex", flexDirection: "column", gap: 18 }}>
          <ChatBubble
            theme={theme}
            lines={["Summarize this note", "without sending it away."]}
          />
          <ChatBubble
            theme={theme}
            align="right"
            title="OWN AI"
            lines={["Done.", "Everything stays local", "with your MLX model."]}
          />
        </div>
      </ScreenShell>
    );
  }

  if (slide === "local") {
    return (
      <ScreenShell theme={theme}>
        <AppHeader theme={theme} title="Model families" />
        <div style={{ padding: "18px 28px", display: "grid", gap: 18 }}>
          {[
            ["Gemma 3", "1.4 GB", "Recommended"],
            ["Qwen 2.5", "2.2 GB", "Best for coding"],
            ["Llama", "3.8 GB", "Balanced"],
          ].map(([name, size, badge]) => (
            <div
              key={name}
              style={{
                background: "rgba(255,255,255,0.92)",
                borderRadius: 30,
                padding: "22px 22px 22px 18px",
                display: "flex",
                alignItems: "center",
                gap: 16,
                boxShadow: `0 18px 40px ${rgba(theme.ink, 0.08)}`,
              }}
            >
              <div
                style={{
                  width: 70,
                  height: 70,
                  borderRadius: 24,
                  background: `linear-gradient(135deg, ${rgba(theme.accent, 0.18)}, ${rgba(
                    theme.accent2,
                    0.18,
                  )})`,
                }}
              />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 26, fontWeight: 800, color: theme.ink }}>{name}</div>
                <div style={{ fontSize: 18, color: theme.muted, marginTop: 6 }}>{size}</div>
              </div>
              <div
                style={{
                  padding: "8px 12px",
                  borderRadius: 999,
                  background: rgba(theme.accent, 0.14),
                  color: theme.ink,
                  fontSize: 14,
                  fontWeight: 700,
                }}
              >
                {badge}
              </div>
            </div>
          ))}
        </div>
      </ScreenShell>
    );
  }

  if (slide === "docs") {
    return (
      <ScreenShell theme={theme}>
        <AppHeader theme={theme} title="Project brief.pdf" />
        <div style={{ padding: "22px 28px", display: "flex", flexDirection: "column", gap: 18 }}>
          <div
            style={{
              background: "rgba(255,255,255,0.92)",
              borderRadius: 30,
              padding: 24,
              boxShadow: `0 18px 40px ${rgba(theme.ink, 0.08)}`,
            }}
          >
            <div style={{ fontSize: 18, color: theme.muted, marginBottom: 16 }}>Relevant context</div>
            <div style={{ height: 14, background: rgba(theme.ink, 0.08), borderRadius: 999, marginBottom: 12 }} />
            <div style={{ height: 14, width: "88%", background: rgba(theme.ink, 0.08), borderRadius: 999, marginBottom: 12 }} />
            <div style={{ height: 14, width: "76%", background: rgba(theme.ink, 0.08), borderRadius: 999 }} />
          </div>
          <ChatBubble
            theme={theme}
            lines={["What are the", "launch risks?"]}
          />
          <ChatBubble
            theme={theme}
            align="right"
            title="OWN AI"
            lines={["Budget drift.", "Vendor dependency.", "No clear fallback path."]}
          />
        </div>
      </ScreenShell>
    );
  }

  return (
    <ScreenShell theme={theme}>
      <AppHeader theme={theme} title="Data & privacy" />
      <div style={{ padding: "18px 28px", display: "grid", gap: 18 }}>
        {[
          ["Chats stored on device", "Your history stays with you."],
          ["Import docs with context", "Ask questions without losing the source."],
          ["Clear privacy language", "See what runs local and what does not."],
        ].map(([title, subtitle]) => (
          <div
            key={title}
            style={{
              borderRadius: 30,
              padding: 24,
              background: "rgba(255,255,255,0.94)",
              boxShadow: `0 18px 40px ${rgba(theme.ink, 0.08)}`,
            }}
          >
            <div style={{ fontSize: 26, fontWeight: 800, color: theme.ink }}>{title}</div>
            <div style={{ fontSize: 20, color: theme.muted, marginTop: 10 }}>{subtitle}</div>
          </div>
        ))}
      </div>
    </ScreenShell>
  );
}

function ScreenshotOrMock({
  slide,
  theme,
}: {
  slide: Slide;
  theme: Theme;
}) {
  const [failed, setFailed] = useState(false);

  if (failed) {
    return <MockScreen slide={slide.id} theme={theme} />;
  }

  return (
    <img
      src={slide.screenshot}
      alt={`${slide.eyebrow} app screenshot`}
      draggable={false}
      onError={() => setFailed(true)}
      style={{
        display: "block",
        width: "100%",
        height: "100%",
        objectFit: "cover",
        objectPosition: "top",
        background: "#f6f2ec",
      }}
    />
  );
}

function SlideCanvas({
  slide,
  theme,
  size,
}: {
  slide: Slide;
  theme: Theme;
  size?: SizeOption;
}) {
  const width = size?.w ?? CANVAS_W;
  const height = size?.h ?? CANVAS_H;
  const scale = width / CANVAS_W;
  const headlineSize = 126 * scale;
  const subheadSize = 38 * scale;
  const labelSize = 26 * scale;

  const isDark = theme.id === "midnight-glow";
  const topGlow = `radial-gradient(circle at 18% 18%, ${rgba(theme.accent, 0.34)} 0, transparent 30%)`;
  const bottomGlow = `radial-gradient(circle at 85% 80%, ${rgba(theme.accent2, 0.28)} 0, transparent 26%)`;
  const backdrop = isDark
    ? `linear-gradient(180deg, ${theme.bg} 0%, ${theme.bg2} 100%)`
    : `linear-gradient(180deg, ${theme.bg} 0%, ${theme.bg2} 100%)`;

  const leftStyle =
    slide.id === "local"
      ? { left: 74 * scale, top: 194 * scale }
      : slide.id === "docs"
        ? { left: 90 * scale, top: 220 * scale }
        : slide.id === "control"
          ? { left: 92 * scale, top: 204 * scale }
          : { left: 88 * scale, top: 186 * scale };

  const phoneStyle =
    slide.id === "docs"
      ? { width: 920 * scale, right: -110 * scale, bottom: -180 * scale, transform: "rotate(-8deg)" }
      : slide.id === "local"
        ? { width: 900 * scale, right: -70 * scale, bottom: -220 * scale, transform: "rotate(-3deg)" }
        : slide.id === "control"
          ? { width: 880 * scale, right: -18 * scale, bottom: -210 * scale, transform: "rotate(-4deg)" }
          : { width: 940 * scale, right: -64 * scale, bottom: -208 * scale, transform: "rotate(0deg)" };

  return (
    <div
      style={{
        width,
        height,
        position: "relative",
        overflow: "hidden",
        background: backdrop,
      }}
    >
      <div style={{ position: "absolute", inset: 0, background: topGlow }} />
      <div style={{ position: "absolute", inset: 0, background: bottomGlow }} />
      <div
        style={{
          position: "absolute",
          inset: 36 * scale,
          borderRadius: 48 * scale,
          border: `1px solid ${rgba(theme.ink, isDark ? 0.1 : 0.06)}`,
          background: `linear-gradient(180deg, ${rgba(theme.panel, 0.55)} 0%, ${rgba(theme.panel, 0)} 100%)`,
        }}
      />

      <div style={{ position: "absolute", ...leftStyle, zIndex: 2, maxWidth: 640 * scale }}>
        <div
          style={{
            display: "inline-flex",
            alignItems: "center",
            gap: 14 * scale,
            padding: `${14 * scale}px ${20 * scale}px`,
            borderRadius: 999,
            background: theme.card,
            boxShadow: `0 24px 50px ${theme.shadow}`,
            color: theme.ink,
            fontSize: labelSize,
            fontWeight: 700,
            letterSpacing: 1.6 * scale,
            textTransform: "uppercase",
          }}
        >
          <span>{slide.label}</span>
          <span style={{ width: 40 * scale, height: 2, background: rgba(theme.ink, 0.18) }} />
          <span>{slide.eyebrow}</span>
        </div>

        <div
          style={{
            marginTop: 42 * scale,
            fontFamily: "var(--font-display), serif",
            color: theme.ink,
            fontSize: headlineSize,
            lineHeight: 0.9,
            fontWeight: 700,
            letterSpacing: -3 * scale,
          }}
        >
          {slide.headline.map((line) => (
            <div key={line}>{line}</div>
          ))}
        </div>

        <div
          style={{
            marginTop: 34 * scale,
            maxWidth: 520 * scale,
            color: rgba(theme.ink, isDark ? 0.82 : 0.72),
            fontSize: subheadSize,
            lineHeight: 1.22,
            fontWeight: 500,
          }}
        >
          {slide.subhead}
        </div>
      </div>

      <div
        style={{
          position: "absolute",
          zIndex: 2,
          filter: `drop-shadow(0 60px 80px ${theme.shadow})`,
          ...phoneStyle,
        }}
      >
        <PhoneFrame>
          <ScreenshotOrMock slide={slide} theme={theme} />
        </PhoneFrame>
      </div>

      {slide.id === "hero" ? (
        <img
          src="/app-icon.png"
          alt=""
          draggable={false}
          style={{
            position: "absolute",
            right: 122 * scale,
            top: 146 * scale,
            width: 134 * scale,
            height: 134 * scale,
            borderRadius: 30 * scale,
            boxShadow: `0 24px 60px ${rgba(theme.accent2, 0.24)}`,
          }}
        />
      ) : null}
    </div>
  );
}

function PreviewCard({
  slide,
  theme,
  onExport,
}: {
  slide: Slide;
  theme: Theme;
  onExport: () => void;
}) {
  return (
    <div
      style={{
        background: "rgba(255,255,255,0.72)",
        borderRadius: 28,
        padding: 16,
        boxShadow: "0 20px 50px rgba(15,23,42,0.08)",
      }}
    >
      <div
        style={{
          width: PREVIEW_W,
          height: PREVIEW_H,
          overflow: "hidden",
          borderRadius: 20,
          margin: "0 auto",
          background: "#fff",
        }}
      >
        <div
          style={{
            transform: `scale(${PREVIEW_W / CANVAS_W})`,
            transformOrigin: "top left",
            width: CANVAS_W,
            height: CANVAS_H,
          }}
        >
          <SlideCanvas slide={slide} theme={theme} />
        </div>
      </div>

      <div style={{ display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 14 }}>
        <div>
          <div style={{ fontWeight: 800, color: "#0f172a" }}>{slide.eyebrow}</div>
          <div style={{ color: "#64748b", fontSize: 14 }}>{slide.headline.join(" ")}</div>
        </div>
        <button
          onClick={onExport}
          style={{
            border: "none",
            borderRadius: 999,
            padding: "10px 14px",
            background: "#0f172a",
            color: "white",
            fontWeight: 700,
            cursor: "pointer",
          }}
        >
          Export PNG
        </button>
      </div>
    </div>
  );
}

export default function ScreenshotsPage() {
  const [themeId, setThemeId] = useState<ThemeId>("sunrise-private");
  const [sizeLabel, setSizeLabel] = useState<SizeOption["label"]>('6.9"');
  const [isExporting, setIsExporting] = useState(false);
  const exportRefs = useRef<Record<string, HTMLDivElement | null>>({});

  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const themeParam = params.get("theme") as ThemeId | null;
    const sizeParam = params.get("size");
    if (themeParam && themeParam in THEMES) {
      setThemeId(themeParam);
    }
    if (sizeParam && IPHONE_SIZES.some((option) => option.label === sizeParam)) {
      setSizeLabel(sizeParam as SizeOption["label"]);
    }
  }, []);

  const theme = THEMES[themeId];
  const size = useMemo(
    () => IPHONE_SIZES.find((option) => option.label === sizeLabel) ?? IPHONE_SIZES[0],
    [sizeLabel],
  );

  async function exportSlide(slide: Slide) {
    const node = exportRefs.current[slide.id];
    if (!node) {
      return;
    }

    const dataUrl = await toPng(node, {
      pixelRatio: 1,
      cacheBust: true,
      width: size.w,
      height: size.h,
    });

    const link = document.createElement("a");
    link.href = dataUrl;
    link.download = `own-ai-${slide.label}-${slide.id}-${size.w}x${size.h}.png`;
    link.click();
  }

  async function exportAll() {
    setIsExporting(true);
    try {
      for (const slide of SLIDES) {
        await exportSlide(slide);
      }
    } finally {
      setIsExporting(false);
    }
  }

  return (
    <main
      style={{
        minHeight: "100vh",
        padding: "32px 24px 80px",
        background:
          "radial-gradient(circle at top left, rgba(255,255,255,0.8), transparent 32%), linear-gradient(180deg, #f6efe6 0%, #fdf9f3 100%)",
      }}
    >
      <div style={{ maxWidth: 1420, margin: "0 auto" }}>
        <section
          style={{
            padding: 28,
            borderRadius: 32,
            background: "rgba(255,255,255,0.78)",
            backdropFilter: "blur(18px)",
            boxShadow: "0 24px 80px rgba(15,23,42,0.08)",
          }}
        >
          <div style={{ display: "flex", flexWrap: "wrap", gap: 18, alignItems: "center", justifyContent: "space-between" }}>
            <div>
              <div style={{ color: "#9a3412", fontWeight: 700, letterSpacing: 1.8, textTransform: "uppercase", fontSize: 13 }}>
                Own AI
              </div>
              <h1
                style={{
                  margin: "10px 0 8px",
                  fontFamily: "var(--font-display), serif",
                  fontSize: 52,
                  lineHeight: 0.95,
                  color: "#111827",
                }}
              >
                App Store screenshot studio
              </h1>
              <p style={{ margin: 0, maxWidth: 760, color: "#64748b", fontSize: 18, lineHeight: 1.5 }}>
                Six conversion-focused iPhone slides for privacy, local chat, document Q&amp;A, voice mode, model choice, and user control.
              </p>
            </div>

            <button
              onClick={exportAll}
              disabled={isExporting}
              style={{
                border: "none",
                borderRadius: 999,
                padding: "16px 22px",
                background: "#111827",
                color: "white",
                fontWeight: 800,
                cursor: isExporting ? "progress" : "pointer",
              }}
            >
              {isExporting ? "Exporting..." : `Export all ${SLIDES.length} PNGs`}
            </button>
          </div>

          <div style={{ display: "flex", flexWrap: "wrap", gap: 12, marginTop: 24 }}>
            {Object.values(THEMES).map((themeOption) => (
              <ControlChip
                key={themeOption.id}
                active={themeOption.id === themeId}
                onClick={() => setThemeId(themeOption.id)}
              >
                {themeOption.name}
              </ControlChip>
            ))}

            <select
              value={sizeLabel}
              onChange={(event) => setSizeLabel(event.target.value as SizeOption["label"])}
              style={{
                border: "none",
                borderRadius: 999,
                padding: "10px 14px",
                background: "rgba(255,255,255,0.7)",
                color: "#334155",
                fontWeight: 600,
              }}
            >
              {IPHONE_SIZES.map((option) => (
                <option key={option.label} value={option.label}>
                  {option.label} · {option.w}×{option.h}
                </option>
              ))}
            </select>
          </div>
        </section>

        <section
          style={{
            marginTop: 26,
            display: "grid",
            gridTemplateColumns: "repeat(auto-fit, minmax(352px, 1fr))",
            gap: 22,
          }}
        >
          {SLIDES.map((slide) => (
            <PreviewCard
              key={slide.id}
              slide={slide}
              theme={theme}
              onExport={() => exportSlide(slide)}
            />
          ))}
        </section>
      </div>

      <div
        style={{
          position: "fixed",
          left: -10000,
          top: 0,
          pointerEvents: "none",
          opacity: 0,
        }}
      >
        {SLIDES.map((slide) => (
          <div
            key={slide.id}
            ref={(node) => {
              exportRefs.current[slide.id] = node;
            }}
          >
            <SlideCanvas slide={slide} theme={theme} size={size} />
          </div>
        ))}
      </div>
    </main>
  );
}
