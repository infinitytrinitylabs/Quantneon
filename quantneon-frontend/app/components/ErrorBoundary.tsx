"use client";

import React, { Component, ErrorInfo, ReactNode } from "react";

interface Props {
  children: ReactNode;
  fallback?: ReactNode;
}

interface State {
  hasError: boolean;
  error?: Error;
}

class ErrorBoundary extends Component<Props, State> {
  constructor(props: Props) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: Error): State {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    console.error("ErrorBoundary caught an error:", error, errorInfo);
  }

  render() {
    if (this.state.hasError) {
      if (this.props.fallback) {
        return this.props.fallback;
      }

      return (
        <div className="flex items-center justify-center w-full h-full bg-[#020010]">
          <div className="text-center p-8 max-w-md">
            <div
              className="text-[#ff00ff] text-2xl tracking-[0.2em] mb-4"
              style={{ textShadow: "0 0 16px #ff00ff" }}
            >
              ⚠ SYSTEM ERROR
            </div>
            <div className="text-[#00f5ff] text-sm mb-6 tracking-wider">
              {this.state.error?.message || "An unexpected error occurred"}
            </div>
            <button
              onClick={() => window.location.reload()}
              className="px-6 py-2 text-sm tracking-widest border cursor-pointer"
              style={{
                borderColor: "#00f5ff",
                color: "#00f5ff",
                background: "rgba(0, 50, 80, 0.5)",
                textShadow: "0 0 8px #00f5ff",
                boxShadow: "0 0 16px rgba(0,245,255,0.3)",
              }}
            >
              RELOAD NEON CITY
            </button>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
