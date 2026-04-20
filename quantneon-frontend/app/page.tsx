"use client";

import dynamic from "next/dynamic";
import { useState, useCallback } from "react";
import HudOverlay from "./components/HudOverlay";
import ErrorBoundary from "./components/ErrorBoundary";

// R3F canvas must be client-only; disable SSR
const NeonScene = dynamic(() => import("./components/NeonScene"), { ssr: false });

export default function Home() {
  const [inRoom, setInRoom] = useState(false);

  const handleEnterRoom = useCallback(() => {
    setInRoom((prev) => !prev);
  }, []);

  return (
    <ErrorBoundary>
      <div className="relative w-screen h-screen overflow-hidden bg-[#020010]">
        {/* 3D canvas fills entire viewport */}
        <NeonScene onEnterRoom={handleEnterRoom} />

        {/* 2D HUD overlay */}
        <HudOverlay onEnterRoom={handleEnterRoom} inRoom={inRoom} />
      </div>
    </ErrorBoundary>
  );
}

