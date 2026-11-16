import type { NavigationState } from './GraphNavigation'
export type Route = {shelf:string|null; notebook:string|null; note:string|null; compose:boolean; filter?:string}
export type Location = {route:Route; search:string; graph:NavigationState}
export const sameLocation = (a:Location,b:Location) => JSON.stringify(a) === JSON.stringify(b)
export const newGraphVisit = (a:NavigationState,b:NavigationState) =>
  a.selectedId !== b.selectedId || a.localId !== b.localId || a.depth !== b.depth ||
  a.notebook !== b.notebook || a.tag !== b.tag || a.includeIsolated !== b.includeIsolated
