import type { Metadata } from "next";
import { Fraunces, Sora } from "next/font/google";
import "./globals.css";

const sora = Sora({
  subsets: ["latin"],
  variable: "--font-sans",
});

const fraunces = Fraunces({
  subsets: ["latin"],
  variable: "--font-display",
});

export const metadata: Metadata = {
  title: "Own AI App Store Screenshots",
  description: "Exportable App Store screenshot generator for Own AI.",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body className={`${sora.variable} ${fraunces.variable}`}>{children}</body>
    </html>
  );
}
