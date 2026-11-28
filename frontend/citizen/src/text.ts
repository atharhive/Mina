import { CATEGORY, KIND, SAFETY, type DisplayStatus, type Link, type OutboxItem } from "@mina/shared";

const en = {
  locale: "en-IN",
  area: (n: number) => `Area ${n} · change`,
  link: {
    online: "Online",
    offline: "Offline — reports are saved on this phone",
    unreachable: "Cannot reach the server — reports are saved on this phone",
  } as Record<Link, string>,
  disclaimer: "MINA is a research system and not a replacement for official emergency services. If you can reach them, call them.",
  demo: "Demonstration with synthetic data: do not enter personal details.",
  areaLabel: "Your area number",
  areaHint: (max: number) => `Given by your local responders, from 1 to ${max}.`,
  proceed: "Continue",
  cancel: "Cancel",
  requestHelp: "Request help",
  mySafety: "My safety",
  safe: "I am safe",
  needHelp: "I need help",
  safetyNote: "Your safety status is shown only to responders of your area.",
  alerts: "Alerts for your area",
  noAlerts: "No alerts received.",
  myReports: "My reports",
  noReports: "Nothing reported from this phone.",
  whatNeed: "What do you need?",
  whatHappening: "What is happening?",
  addLocation: "Add my approximate location (about 100 m)",
  chooseCategory: "Choose what kind of help you need.",
  noLocation: "Saved without a location: this phone could not determine it.",
  saveFailed: "Could not save the report.",
  saving: "Saving…",
  saveSend: "Save and send",
  categories: {
    [CATEGORY.medical]: "Medical", [CATEGORY.rescue]: "Rescue", [CATEGORY.evacuation]: "Evacuation",
    [CATEGORY.food]: "Food", [CATEGORY.water]: "Water",
  } as Record<number, string>,
  /** Wording never suggests that anyone has a report before the server has confirmed it. */
  status: {
    saved: "Saved on this phone — not sent yet",
    waiting: "Waiting to send",
    delivered: "Delivered to server",
    acknowledged: "Acknowledged by a responder",
    in_progress: "Responders are working on it",
    resolved: "Resolved",
    rejected: "Not accepted",
  } as Record<DisplayStatus, string>,
  iAmSafe: "Safety: I am safe",
  iNeedHelp: "Safety: I need help",
  help: (what?: string) => `Help: ${what ?? "request"}`,
};

export type Strings = typeof en;

const hi: Strings = {
  locale: "hi-IN",
  area: (n) => `इलाका ${n} · बदलें`,
  link: {
    online: "ऑनलाइन",
    offline: "ऑफ़लाइन — रिपोर्ट इस फ़ोन पर सहेजी जा रही हैं",
    unreachable: "सर्वर तक पहुँच नहीं — रिपोर्ट इस फ़ोन पर सहेजी जा रही हैं",
  },
  disclaimer: "MINA एक शोध प्रणाली है और सरकारी आपातकालीन सेवाओं का विकल्प नहीं है। अगर आप उनसे संपर्क कर सकते हैं, तो उन्हें फ़ोन करें।",
  demo: "कृत्रिम डेटा वाला प्रदर्शन: निजी जानकारी न डालें।",
  areaLabel: "आपके इलाके का नंबर",
  areaHint: (max) => `आपके स्थानीय बचाव दल से मिलता है, 1 से ${max} तक।`,
  proceed: "आगे बढ़ें",
  cancel: "रद्द करें",
  requestHelp: "मदद माँगें",
  mySafety: "मेरी सुरक्षा",
  safe: "मैं सुरक्षित हूँ",
  needHelp: "मुझे मदद चाहिए",
  safetyNote: "आपकी सुरक्षा स्थिति केवल आपके इलाके के बचाव दल को दिखाई जाती है।",
  alerts: "आपके इलाके की चेतावनियाँ",
  noAlerts: "कोई चेतावनी नहीं मिली।",
  myReports: "मेरी रिपोर्ट",
  noReports: "इस फ़ोन से अभी कोई रिपोर्ट नहीं की गई है।",
  whatNeed: "आपको क्या चाहिए?",
  whatHappening: "क्या हो रहा है?",
  addLocation: "मेरा अनुमानित स्थान जोड़ें (लगभग 100 मीटर)",
  chooseCategory: "चुनें कि आपको किस तरह की मदद चाहिए।",
  noLocation: "स्थान के बिना सहेजा गया: यह फ़ोन स्थान पता नहीं कर सका।",
  saveFailed: "रिपोर्ट सहेजी नहीं जा सकी।",
  saving: "सहेजा जा रहा है…",
  saveSend: "सहेजें और भेजें",
  categories: {
    [CATEGORY.medical]: "चिकित्सा", [CATEGORY.rescue]: "बचाव", [CATEGORY.evacuation]: "निकासी",
    [CATEGORY.food]: "भोजन", [CATEGORY.water]: "पानी",
  },
  status: {
    saved: "इस फ़ोन पर सहेजी गई — अभी भेजी नहीं गई",
    waiting: "भेजे जाने की प्रतीक्षा में",
    delivered: "सर्वर तक पहुँच गई",
    acknowledged: "बचाव कर्मी ने मिलने की पुष्टि की",
    in_progress: "बचाव दल इस पर काम कर रहा है",
    resolved: "समाधान हो गया",
    rejected: "स्वीकार नहीं की गई",
  },
  iAmSafe: "सुरक्षा: मैं सुरक्षित हूँ",
  iNeedHelp: "सुरक्षा: मुझे मदद चाहिए",
  help: (what) => `मदद: ${what ?? "अनुरोध"}`,
};

const mr: Strings = {
  locale: "mr-IN",
  area: (n) => `विभाग ${n} · बदला`,
  link: {
    online: "ऑनलाइन",
    offline: "ऑफलाइन — अहवाल या फोनवर जतन केले जात आहेत",
    unreachable: "सर्व्हरशी संपर्क होत नाही — अहवाल या फोनवर जतन केले जात आहेत",
  },
  disclaimer: "MINA ही संशोधन प्रणाली आहे; ती अधिकृत आपत्कालीन सेवांना पर्याय नाही. त्यांच्याशी संपर्क करता येत असल्यास त्यांना फोन करा.",
  demo: "कृत्रिम माहितीसह प्रात्यक्षिक: वैयक्तिक माहिती भरू नका.",
  areaLabel: "तुमच्या विभागाचा क्रमांक",
  areaHint: (max) => `स्थानिक बचाव पथकाकडून मिळतो, 1 ते ${max}.`,
  proceed: "पुढे जा",
  cancel: "रद्द करा",
  requestHelp: "मदत मागा",
  mySafety: "माझी सुरक्षा",
  safe: "मी सुरक्षित आहे",
  needHelp: "मला मदत हवी आहे",
  safetyNote: "तुमची सुरक्षा स्थिती फक्त तुमच्या विभागातील बचाव पथकाला दिसते.",
  alerts: "तुमच्या विभागासाठी सूचना",
  noAlerts: "कोणतीही सूचना मिळालेली नाही.",
  myReports: "माझे अहवाल",
  noReports: "या फोनवरून अद्याप काहीही कळवलेले नाही.",
  whatNeed: "तुम्हाला काय हवे आहे?",
  whatHappening: "काय घडत आहे?",
  addLocation: "माझे अंदाजे ठिकाण जोडा (सुमारे 100 मीटर)",
  chooseCategory: "तुम्हाला कोणती मदत हवी आहे ते निवडा.",
  noLocation: "ठिकाणाशिवाय जतन केले: या फोनला ठिकाण शोधता आले नाही.",
  saveFailed: "अहवाल जतन करता आला नाही.",
  saving: "जतन होत आहे…",
  saveSend: "जतन करा आणि पाठवा",
  categories: {
    [CATEGORY.medical]: "वैद्यकीय", [CATEGORY.rescue]: "बचाव", [CATEGORY.evacuation]: "स्थलांतर",
    [CATEGORY.food]: "अन्न", [CATEGORY.water]: "पाणी",
  },
  status: {
    saved: "या फोनवर जतन केले — अजून पाठवलेले नाही",
    waiting: "पाठवण्याच्या प्रतीक्षेत",
    delivered: "सर्व्हरवर पोहोचले",
    acknowledged: "बचाव कार्यकर्त्याने मिळाल्याची पुष्टी केली",
    in_progress: "बचाव पथक यावर काम करत आहे",
    resolved: "निवारण झाले",
    rejected: "स्वीकारले नाही",
  },
  iAmSafe: "सुरक्षा: मी सुरक्षित आहे",
  iNeedHelp: "सुरक्षा: मला मदत हवी आहे",
  help: (what) => `मदत: ${what ?? "विनंती"}`,
};

export const STRINGS = { en, hi, mr };
export type Lang = keyof typeof STRINGS;
export const LANGUAGE_NAMES: ReadonlyArray<[Lang, string]> = [["en", "English"], ["hi", "हिन्दी"], ["mr", "मराठी"]];

const isLang = (value: unknown): value is Lang => value === "en" || value === "hi" || value === "mr";

/** The choice made on this phone, else the phone's own language, else English. */
export function initialLang(): Lang {
  try {
    const kept = localStorage.getItem("lang");
    if (isLang(kept)) return kept;
  } catch { /* storage blocked: fall through to the phone's language */ }
  const phone = navigator.language.slice(0, 2);
  return isLang(phone) ? phone : "en";
}

export function keepLang(lang: Lang) {
  try { localStorage.setItem("lang", lang); } catch { /* the choice then lasts until reload */ }
}

export function title(item: OutboxItem, t: Strings): string {
  if (item.payload.kind === KIND.safety_reported)
    return item.payload.status === SAFETY.safe ? t.iAmSafe : t.iNeedHelp;
  return t.help(t.categories[item.payload.category ?? 0]);
}

export const time = (ms: number, t: Strings) => new Date(ms).toLocaleString(t.locale, { dateStyle: "medium", timeStyle: "short" });
