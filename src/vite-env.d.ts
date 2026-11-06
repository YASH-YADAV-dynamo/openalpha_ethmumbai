/// <reference types="vite/client" />

// main.tsx imports './index.css?v=N' as a preview cache-buster; keep N in sync with that import.
declare module '*.css?v=3'
