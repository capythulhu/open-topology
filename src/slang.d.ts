declare module '*.slang' {
  export const code: string;
  export const reflection: import('./program').Reflection;
}
