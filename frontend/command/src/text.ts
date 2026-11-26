import { CATEGORY, KIND, STATUS } from "@mina/shared";

export const CATEGORY_TEXT: Record<number, string> = {
  [CATEGORY.medical]: "Medical", [CATEGORY.rescue]: "Rescue", [CATEGORY.evacuation]: "Evacuation",
  [CATEGORY.food]: "Food", [CATEGORY.water]: "Water",
};
export const STATUS_TEXT: Record<number, string> = {
  [STATUS.open]: "Unanswered", [STATUS.acknowledged]: "Acknowledged", [STATUS.in_progress]: "In progress", [STATUS.resolved]: "Resolved",
};
export const STATUS_TONE: Record<number, string> = {
  [STATUS.open]: "text-alarm", [STATUS.acknowledged]: "text-wait", [STATUS.in_progress]: "text-wait", [STATUS.resolved]: "text-safe",
};
export function actionText(kind: number, target: number): string {
  if (kind === KIND.sos_acknowledged) return "Acknowledge";
  if (kind === KIND.incident_resolved) return "Resolve";
  return target === STATUS.in_progress ? "Start work" : "Stand down";
}
export const clock = (seconds: number) => new Date(seconds * 1000).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" });
export const place = (lat: number | null, lon: number | null) =>
  lat === null || lon === null ? "not shared" : `${(lat / 1e5).toFixed(3)}, ${(lon / 1e5).toFixed(3)}`;
