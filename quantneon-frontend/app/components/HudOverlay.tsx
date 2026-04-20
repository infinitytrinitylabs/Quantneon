"use client";

import { useState, useEffect } from "react";

interface HudOverlayProps {
  onEnterRoom: () => void;
  inRoom: boolean;
}

export default function HudOverlay({ onEnterRoom, inRoom }: HudOverlayProps) {
  const [time, setTime] = useState("");
  const [fps, setFps] = useState(0);

  useEffect(() => {
    const tick = () => {
      const now = new Date();
      setTime(
        now.toLocaleTimeString("en-US", {
          hour: "2-digit",
          minute: "2-digit",
          second: "2-digit",
          hour12: false,
        })
      );
    };
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    let frameCount = 0;
    let lastSample = performance.now();
    let animationFrameId = 0;

    const sampleFps = (now: number) => {
      frameCount += 1;
      const elapsed = now - lastSample;

      if (elapsed >= 1000) {
        setFps(Math.round((frameCount * 1000) / elapsed));
        frameCount = 0;
        lastSample = now;
      }

      animationFrameId = window.requestAnimationFrame(sampleFps);
    };

    animationFrameId = window.requestAnimationFrame(sampleFps);

    return () => {
      if (animationFrameId) {
        window.cancelAnimationFrame(animationFrameId);
      }
    };
  }, []);

  return (
    <>
      {/* Top bar */}
      <header className="absolute top-0 left-0 right-0 z-10 flex items-center justify-between px-6 py-3 pointer-events-none select-none">
        <div className="flex items-center gap-3">
          <span
            className="text-[#00f5ff] text-xl font-bold tracking-[0.25em] flicker"
            style={{ textShadow: "0 0 12px #00f5ff, 0 0 24px #00f5ff" }}
          >
            QUANTNEON
          </span>
          <span className="text-[#8b00ff] text-xs tracking-widest">
            NEON CITY — AR/VR HUB
          </span>
        </div>

        <div className="flex items-center gap-6 text-xs text-[#4466aa] tracking-widest">
          <span>
            IDENTITY:{" "}
            <span className="text-[#00f5ff]">QUANTMAIL.ID</span>
          </span>
          <span>
            SYS:{" "}
            <span className="text-[#ff00ff]">{fps || "--"} FPS</span>
          </span>
          <span className="text-[#00f5ff] font-mono">{time}</span>
        </div>
      </header>

      {/* Bottom-left controls hint */}
      <div className="absolute bottom-6 left-6 z-10 text-[10px] text-[#334466] tracking-widest pointer-events-none select-none leading-relaxed">
        <div>🖱 DRAG — ORBIT CAMERA</div>
        <div>🖱 SCROLL — ZOOM</div>
        <div>🖱 RIGHT-DRAG — PAN</div>
        <div className="mt-1 text-[#3300aa]">CLICK PORTAL → ENTER CHILL ROOM</div>
      </div>

      {/* Bottom-right ecosystem links */}
      <div className="absolute bottom-6 right-6 z-10 flex flex-col gap-1 text-[10px] tracking-widest pointer-events-none select-none text-right">
        {["QUANTMAIL", "QUANTCHAT", "QUANTCHILL", "QUANTTUBE", "QUANTSINK"].map((app) => (
          <span key={app} className="text-[#1a2255]">
            {app}
          </span>
        ))}
      </div>

      {/* "Enter Chill Room" button — 2D fallback */}
      {!inRoom && (
        <button
          onClick={onEnterRoom}
          className="absolute bottom-6 left-1/2 -translate-x-1/2 z-10 px-8 py-2 text-sm tracking-widest border cursor-pointer"
          style={{
            borderColor: "#ff00ff",
            color: "#ff00ff",
            background: "rgba(50, 0, 80, 0.5)",
            textShadow: "0 0 8px #ff00ff",
            boxShadow: "0 0 16px rgba(255,0,255,0.3), inset 0 0 16px rgba(255,0,255,0.05)",
          }}
        >
          ▶&nbsp; ENTER CHILL ROOM
        </button>
      )}

      {/* "In Room" overlay */}
      {inRoom && (
        <div className="absolute inset-0 z-20 flex items-center justify-center bg-[#020010]/80 backdrop-blur-sm">
          <div className="text-center">
            <div
              className="text-[#ff00ff] text-3xl tracking-[0.3em] mb-4 neon-text"
              style={{ textShadow: "0 0 20px #ff00ff, 0 0 40px #ff00ff" }}
            >
              ENTERING CHILL ROOM
            </div>
            <div className="text-[#00f5ff] text-sm tracking-widest mb-6">
              CONNECTING VIA QUANTCHAT · QUANTCHILL
            </div>
            <div className="w-72 h-0.5 bg-[#0a003a] rounded overflow-hidden mx-auto mb-6">
              <div className="h-full bg-gradient-to-r from-[#ff00ff] to-[#00f5ff] animate-pulse rounded" />
            </div>
            <button
              onClick={onEnterRoom}
              className="text-xs text-[#334466] tracking-widest underline cursor-pointer"
            >
              CANCEL / STAY IN NEON CITY
            </button>
          </div>
        </div>
      )}
    </>
  );
}
