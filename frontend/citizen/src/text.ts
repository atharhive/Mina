import { CATEGORY, KIND, SAFETY, type DisplayStatus, type OutboxItem } from "@mina/shared";

export const CATEGORIES: ReadonlyArray<[number, string]> = [
  [CATEGORY.medical, "Medical"], [CATEGORY.rescue, "Rescue"], [CATEGORY.evacuation, "Evacuation"],
  [CATEGORY.food, "Food"], [CATEGORY.water, "Water"],
];

/** Wording never suggests that anyone has a report before the server has confirmed it. */
export const STATUS_TEXT: Record<DisplayStatus, string> = {
  saved: "Saved on this phone — not sent yet",
  waiting: "Waiting to send",
  delivered: "Delivered to server",
  acknowledged: "Acknowledged by a responder",
  in_progress: "Responders are working on it",
  resolved: "Resolved",
  rejected: "Not accepted",
};

export function title(item: OutboxItem): string {
  if (item.payload.kind === KIND.safety_reported)
    return item.payload.status === SAFETY.safe ? "Safety: I am safe" : "Safety: I need help";
  return `Help: ${CATEGORIES.find(([code]) => code === item.payload.category)?.[1] ?? "request"}`;
}

export const time = (ms: number) => new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
