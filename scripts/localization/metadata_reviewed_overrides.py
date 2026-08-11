#!/usr/bin/env python3
"""Reviewed App Store metadata fragments that must not use statistical MT."""

from __future__ import annotations


UNLOCK = "bontecou.Voxboard.unlock"
FAMILY = "bontecou.Voxboard.family"
FAMILY_UPGRADE = "bontecou.Voxboard.familyUpgrade"


def products(
    unlock_name: str,
    unlock_description: str,
    family_name: str,
    family_description: str,
    upgrade_name: str,
    upgrade_description: str,
) -> dict[str, dict[str, str]]:
    return {
        UNLOCK: {"displayName": unlock_name, "description": unlock_description},
        FAMILY: {"displayName": family_name, "description": family_description},
        FAMILY_UPGRADE: {"displayName": upgrade_name, "description": upgrade_description},
    }


IAP_REVIEWED = {
    "ar-SA": products(
        "Vox.md فردي غير محدود", "التقاط ونسخ صوتي بلا حدود",
        "Vox.md عائلي غير محدود", "وصول غير محدود مع المشاركة العائلية",
        "Vox.md ترقية عائلية", "أضف المشاركة العائلية إلى خطتك",
    ),
    "de-DE": products(
        "Vox.md Privat unbegrenzt", "Unbegrenzte Erfassung und Transkription",
        "Vox.md Familie unbegrenzt", "Unbegrenzt mit Familienfreigabe",
        "Vox.md Familien-Upgrade", "Familienfreigabe hinzufügen",
    ),
    "es-ES": products(
        "Vox.md Individual Ilimitado", "Captura y transcripción ilimitadas",
        "Vox.md Familia Ilimitada", "Acceso ilimitado con En familia",
        "Vox.md Mejora familiar", "Añade En familia a tu plan",
    ),
    "es-MX": products(
        "Vox.md Individual Ilimitado", "Captura y transcripción ilimitadas",
        "Vox.md Familia Ilimitada", "Acceso ilimitado con En familia",
        "Vox.md Mejora familiar", "Añade En familia a tu plan",
    ),
    "fr-FR": products(
        "Vox.md Individuel illimité", "Capture et transcription illimitées",
        "Vox.md Famille illimitée", "Accès illimité avec Partage familial",
        "Vox.md Mise à niveau famille", "Ajouter le Partage familial",
    ),
    "fr-CA": products(
        "Vox.md Individuel illimité", "Capture et transcription illimitées",
        "Vox.md Famille illimitée", "Accès illimité avec Partage familial",
        "Vox.md Mise à niveau famille", "Ajouter le Partage familial",
    ),
    "hi": products(
        "Vox.md व्यक्तिगत अनलिमिटेड", "अनलिमिटेड कैप्चर और ट्रांसक्रिप्शन",
        "Vox.md परिवार अनलिमिटेड", "फ़ैमिली शेयरिंग के साथ अनलिमिटेड एक्सेस",
        "Vox.md परिवार अपग्रेड", "अपने प्लान में फ़ैमिली शेयरिंग जोड़ें",
    ),
    "id": products(
        "Vox.md Individu Tanpa Batas", "Tangkapan dan transkripsi tanpa batas",
        "Vox.md Keluarga Tanpa Batas", "Akses tanpa batas dengan Keluarga Berbagi",
        "Vox.md Upgrade Keluarga", "Tambahkan Keluarga Berbagi ke paket",
    ),
    "it": products(
        "Vox.md Individuale illimitato", "Acquisizione e trascrizione illimitate",
        "Vox.md Famiglia illimitata", "Accesso illimitato con In famiglia",
        "Vox.md Upgrade famiglia", "Aggiungi In famiglia al tuo piano",
    ),
    "ja": products(
        "Vox.md 個人向け無制限", "キャプチャと文字起こしが無制限",
        "Vox.md ファミリー無制限", "ファミリー共有付きの無制限アクセス",
        "Vox.md ファミリーアップグレード", "プランにファミリー共有を追加",
    ),
    "ko": products(
        "Vox.md 개인 무제한", "캡처 및 전사 무제한",
        "Vox.md 가족 무제한", "가족 공유가 포함된 무제한 이용",
        "Vox.md 가족 업그레이드", "요금제에 가족 공유 추가",
    ),
    "nl-NL": products(
        "Vox.md Individueel onbeperkt", "Onbeperkt vastleggen en transcriberen",
        "Vox.md Gezin onbeperkt", "Onbeperkt met Delen met gezin",
        "Vox.md Gezinsupgrade", "Voeg Delen met gezin toe",
    ),
    "pl": products(
        "Vox.md Indywidualny bez limitu", "Przechwytywanie i transkrypcja bez limitu",
        "Vox.md Rodzinny bez limitu", "Bez limitu z Chmurą rodzinną",
        "Vox.md Ulepszenie rodzinne", "Dodaj Chmurę rodzinną do planu",
    ),
    "pt-BR": products(
        "Vox.md Individual Ilimitado", "Captura e transcrição ilimitadas",
        "Vox.md Família Ilimitada", "Acesso ilimitado com a família",
        "Vox.md Upgrade Família", "Adicione Compartilhamento Familiar",
    ),
    "ru": products(
        "Vox.md Личный безлимит", "Захват и транскрипция без ограничений",
        "Vox.md Семейный безлимит", "Безлимитный доступ для семьи",
        "Vox.md Семейное обновление", "Добавить Семейный доступ",
    ),
    "th": products(
        "Vox.md บุคคลไม่จำกัด", "จับภาพและถอดเสียงไม่จำกัด",
        "Vox.md ครอบครัวไม่จำกัด", "ใช้งานไม่จำกัดพร้อมการแชร์ในครอบครัว",
        "Vox.md อัปเกรดครอบครัว", "เพิ่มการแชร์ในครอบครัวในแผน",
    ),
    "tr": products(
        "Vox.md Bireysel Sınırsız", "Sınırsız yakalama ve transkripsiyon",
        "Vox.md Aile Sınırsız", "Aile Paylaşımı ile sınırsız erişim",
        "Vox.md Aile Yükseltmesi", "Planına Aile Paylaşımı ekle",
    ),
    "uk": products(
        "Vox.md Особистий безліміт", "Захоплення й транскрипція без обмежень",
        "Vox.md Сімейний безліміт", "Безлімітний доступ для сім’ї",
        "Vox.md Сімейне оновлення", "Додати Сімейний доступ до плану",
    ),
    "vi": products(
        "Vox.md Cá nhân vô hạn", "Ghi nhanh và chép lời không giới hạn",
        "Vox.md Gia đình vô hạn", "Truy cập vô hạn với Chia sẻ gia đình",
        "Vox.md Nâng cấp gia đình", "Thêm Chia sẻ gia đình vào gói",
    ),
    "zh-Hans": products(
        "Vox.md 个人无限版", "无限采集与转录",
        "Vox.md 家庭无限版", "无限访问，支持家人共享",
        "Vox.md 家庭升级", "为方案添加家人共享",
    ),
    "zh-Hant": products(
        "Vox.md 個人無限版", "無限擷取與轉錄",
        "Vox.md 家庭無限版", "無限存取，支援家人共享",
        "Vox.md 家庭升級", "將家人共享加入方案",
    ),
}


def store_copy(description: str, promotional: str, release_notes: str) -> dict[str, str]:
    return {
        "description.txt": description.strip(),
        "promotional_text.txt": promotional.strip(),
        "release_notes.txt": release_notes.strip(),
    }


METADATA_REVIEWED = {
    "ar-SA": store_copy(
        """
Vox.md تطبيق التقاط يعمل محليًا مع Obsidian وMarkdown. أرسل النصوص والروابط والصور والملفات وعمليات مسح المستندات والرسومات والتسجيلات الصوتية إلى الملاحظة المناسبة.

تتذكر إعدادات الالتقاط المسبقة الوجهة والقالب والبيانات الوصفية والمرفقات وموضع المحتوى. استخدم Vox.md من التطبيق أو ورقة المشاركة أو لوحة المفاتيح المخصصة أو الأدوات أو الاختصارات أو Apple Watch. تبقى عمليات التسليم المعلقة متاحة لإعادة المحاولة.

يعمل تحويل الكلام إلى نص على الجهاز باستخدام Apple Speech أو Whisper أو Parakeet. لا يتم إرسال الصوت أو النصوص المنسوخة أو المحتوى المكتوب أو مسارات الملفات أو الإشارات المرجعية إلى خوادم Vox.md. يكتب Vox.md ملفات Markdown قياسية في المجلدات وخزائن Obsidian التي تختارها، ولا يتطلب حسابًا أو قاعدة بيانات ملاحظات خاصة.

يحصل المستخدمون الجدد على 15 دقيقة مجانية للنسخ الصوتي و10 عمليات تسليم ناجحة. تفتح عملية شراء واحدة الاستخدام غير المحدود.
""",
        "التقط النصوص والروابط والملفات والصور والمسح والرسومات والصوت إلى Markdown. يبقى النسخ الصوتي على الجهاز.",
        """
جديد: تسميات للمتحدثين على الجهاز في التسجيلات الطويلة.

تحسين: عناصر تحكم أكثر موثوقية للأنشطة المباشرة وحماية أفضل للتسجيلات الطويلة.

إصلاح: تتوافق أدوات الالتقاط السريع والتسجيل السريع الآن مع المظهر الفاتح والداكن.
""",
    ),
    "de-DE": store_copy(
        """
Vox.md ist eine lokal arbeitende Erfassungs-App für Obsidian und Markdown. Sende Text, Links, Fotos, Dateien, Dokument-Scans, Skizzen und Sprache direkt an die passende Notiz.

Aufnahmevoreinstellungen merken sich Ziel, Vorlage, Metadaten, Anhänge und Position. Nutze Vox.md über die App, das Teilen-Menü, die eigene Tastatur, Widgets, Kurzbefehle oder die Apple Watch. Ausstehende Übertragungen können erneut versucht werden.

Die Spracherkennung läuft mit Apple Speech, Whisper oder Parakeet auf dem Gerät. Audio, Transkripte, eingegebene Inhalte, Dateipfade und Lesezeichen werden nicht an Vox.md-Server gesendet. Vox.md schreibt Standard-Markdown in ausgewählte Ordner und Obsidian-Vaults; ein Konto oder eine proprietäre Notizdatenbank ist nicht erforderlich.

Neue Nutzer erhalten 15 kostenlose Transkriptionsminuten und 10 erfolgreiche Übertragungen. Ein einmaliger Kauf schaltet die unbegrenzte Nutzung frei.
""",
        "Erfasse Text, Links, Dateien, Bilder, Scans, Skizzen und Sprache als Markdown. Die Transkription bleibt auf dem Gerät.",
        """
Neu: Sprecherkennzeichnungen auf dem Gerät für lange Aufnahmen.

Verbessert: Zuverlässigere Live-Aktivitätssteuerung und sicherere lange Aufnahmen.

Behoben: Widgets für Schnellerfassung und Schnellaufnahme passen nun zum hellen und dunklen Erscheinungsbild.
""",
    ),
    "es-ES": store_copy(
        """
Vox.md es una app de captura local para Obsidian y Markdown. Envía texto, enlaces, fotos, archivos, escaneos de documentos, dibujos y voz a la nota adecuada.

Los preajustes de captura recuerdan el destino, la plantilla, los metadatos, los adjuntos y la ubicación. Usa Vox.md desde la app, la hoja para compartir, el teclado personalizado, los widgets, Atajos o el Apple Watch. Los envíos pendientes permanecen disponibles para volver a intentarlo.

La conversión de voz a texto se ejecuta en el dispositivo con Apple Speech, Whisper o Parakeet. El audio, las transcripciones, el contenido escrito, las rutas de archivos y los marcadores no se envían a los servidores de Vox.md. Vox.md escribe Markdown estándar en las carpetas y bóvedas de Obsidian que elijas; no requiere una cuenta ni una base de datos de notas propietaria.

Los nuevos usuarios reciben 15 minutos gratuitos de transcripción y 10 envíos correctos. Una compra única desbloquea el uso ilimitado.
""",
        "Captura texto, enlaces, archivos, imágenes, escaneos, dibujos y voz en Markdown. La transcripción permanece en el dispositivo.",
        """
Nuevo: Etiquetas de hablantes en el dispositivo para grabaciones largas.

Mejorado: Controles de Actividades en directo más fiables y grabaciones largas más seguras.

Corregido: Los widgets de Captura rápida y Grabación rápida ahora se adaptan a la apariencia clara y oscura.
""",
    ),
    "fr-FR": store_copy(
        """
Vox.md est une app de capture locale pour Obsidian et Markdown. Envoyez du texte, des liens, des photos, des fichiers, des scans de documents, des croquis et de la voix vers la bonne note.

Les préréglages de capture mémorisent la destination, le modèle, les métadonnées, les pièces jointes et l’emplacement. Utilisez Vox.md depuis l’app, la feuille de partage, le clavier personnalisé, les widgets, Raccourcis ou l’Apple Watch. Les envois en attente restent disponibles pour une nouvelle tentative.

La conversion de la parole en texte s’exécute sur l’appareil avec Apple Speech, Whisper ou Parakeet. L’audio, les transcriptions, le contenu saisi, les chemins de fichiers et les signets ne sont pas envoyés aux serveurs de Vox.md. Vox.md écrit du Markdown standard dans les dossiers et coffres Obsidian choisis ; aucun compte ni aucune base de données de notes propriétaire n’est requis.

Les nouveaux utilisateurs bénéficient de 15 minutes de transcription gratuites et de 10 envois réussis. Un achat unique déverrouille l’utilisation illimitée.
""",
        "Capturez texte, liens, fichiers, images, scans, croquis et voix en Markdown. La transcription reste sur l’appareil.",
        """
Nouveau : étiquettes de locuteurs sur l’appareil pour les longs enregistrements.

Amélioration : commandes d’Activités en direct plus fiables et longs enregistrements mieux protégés.

Correction : les widgets Capture rapide et Enregistrement rapide suivent désormais l’apparence claire ou sombre.
""",
    ),
    "hi": store_copy(
        """
Vox.md, Obsidian और Markdown के लिए लोकल-फर्स्ट कैप्चर ऐप है। टेक्स्ट, लिंक, फ़ोटो, फ़ाइलें, दस्तावेज़ स्कैन, स्केच और आवाज़ सही नोट में भेजें।

कैप्चर प्रीसेट डेस्टिनेशन, टेम्प्लेट, मेटाडेटा, अटैचमेंट और स्थान याद रखते हैं। Vox.md को ऐप, शेयर शीट, कस्टम कीबोर्ड, विजेट, शॉर्टकट या Apple Watch से इस्तेमाल करें। लंबित डिलीवरी दोबारा भेजने के लिए उपलब्ध रहती हैं।

Apple Speech, Whisper या Parakeet से स्पीच-टू-टेक्स्ट डिवाइस पर ही चलता है। ऑडियो, ट्रांसक्रिप्ट, टाइप किया गया कंटेंट, फ़ाइल पाथ और बुकमार्क Vox.md सर्वर पर नहीं भेजे जाते। Vox.md आपकी चुनी हुई फ़ोल्डर और Obsidian वॉल्ट में मानक Markdown लिखता है; किसी अकाउंट या निजी नोट डेटाबेस की ज़रूरत नहीं है।

नए उपयोगकर्ताओं को 15 मिनट का मुफ़्त ट्रांसक्रिप्शन और 10 सफल डिलीवरी मिलती हैं। एक बार की खरीद अनलिमिटेड उपयोग खोलती है।
""",
        "टेक्स्ट, लिंक, फ़ाइलें, इमेज, स्कैन, स्केच और आवाज़ को Markdown में कैप्चर करें। ट्रांसक्रिप्शन डिवाइस पर रहता है।",
        """
नया: लंबी रिकॉर्डिंग के लिए डिवाइस पर स्पीकर लेबल।

बेहतर: अधिक भरोसेमंद लाइव एक्टिविटी कंट्रोल और लंबी रिकॉर्डिंग की बेहतर सुरक्षा।

ठीक किया: क्विक कैप्चर और क्विक रिकॉर्ड विजेट अब लाइट और डार्क रूप से मेल खाते हैं।
""",
    ),
    "id": store_copy(
        """
Vox.md adalah aplikasi tangkapan lokal untuk Obsidian dan Markdown. Kirim teks, tautan, foto, file, pindaian dokumen, sketsa, dan suara ke catatan yang tepat.

Preset Tangkapan mengingat tujuan, templat, metadata, lampiran, dan penempatan. Gunakan Vox.md dari aplikasi, lembar berbagi, papan ketik khusus, widget, Pintasan, atau Apple Watch. Pengiriman tertunda tetap tersedia untuk dicoba lagi.

Ucapan-ke-teks berjalan di perangkat dengan Apple Speech, Whisper, atau Parakeet. Audio, transkrip, konten ketikan, jalur file, dan penanda tidak dikirim ke server Vox.md. Vox.md menulis Markdown standar ke folder dan vault Obsidian yang Anda pilih; akun atau basis data catatan milik vendor tidak diperlukan.

Pengguna baru memperoleh 15 menit transkripsi gratis dan 10 pengiriman berhasil. Satu pembelian membuka penggunaan tanpa batas.
""",
        "Tangkap teks, tautan, file, gambar, pindaian, sketsa, dan suara ke Markdown. Transkripsi tetap di perangkat.",
        """
Baru: Label pembicara di perangkat untuk rekaman panjang.

Peningkatan: Kontrol Aktivitas Langsung lebih andal dan rekaman panjang lebih aman.

Perbaikan: Widget Tangkapan Cepat dan Rekam Cepat kini mengikuti tampilan terang dan gelap.
""",
    ),
    "it": store_copy(
        """
Vox.md è un’app di acquisizione locale per Obsidian e Markdown. Invia testo, link, foto, file, scansioni di documenti, schizzi e voce alla nota giusta.

Le preimpostazioni di acquisizione ricordano destinazione, modello, metadati, allegati e posizione. Usa Vox.md dall’app, dal foglio di condivisione, dalla tastiera personalizzata, dai widget, da Comandi Rapidi o da Apple Watch. Gli invii in sospeso restano disponibili per un nuovo tentativo.

La conversione da voce a testo avviene sul dispositivo con Apple Speech, Whisper o Parakeet. Audio, trascrizioni, contenuti digitati, percorsi dei file e segnalibri non vengono inviati ai server Vox.md. Vox.md scrive Markdown standard nelle cartelle e nei vault Obsidian scelti; non servono un account o un database di note proprietario.

I nuovi utenti ricevono 15 minuti gratuiti di trascrizione e 10 invii riusciti. Un unico acquisto sblocca l’uso illimitato.
""",
        "Acquisisci testo, link, file, immagini, scansioni, schizzi e voce in Markdown. La trascrizione resta sul dispositivo.",
        """
Novità: Etichette dei parlanti sul dispositivo per le registrazioni lunghe.

Migliorato: Controlli delle attività in tempo reale più affidabili e registrazioni lunghe più sicure.

Risolto: I widget Acquisizione rapida e Registrazione rapida ora rispettano l’aspetto chiaro e scuro.
""",
    ),
    "ja": store_copy(
        """
Vox.mdは、ObsidianとMarkdown向けのローカルファーストなキャプチャアプリです。テキスト、リンク、写真、ファイル、書類スキャン、スケッチ、音声を適切なノートへ送れます。

キャプチャプリセットには、保存先、テンプレート、メタデータ、添付ファイル、挿入位置を記憶できます。アプリ、共有シート、カスタムキーボード、ウィジェット、ショートカット、Apple WatchからVox.mdを利用できます。保留中の送信は再試行できます。

音声の文字起こしはApple Speech、Whisper、Parakeetを使ってデバイス上で実行されます。音声、文字起こし、入力内容、ファイルパス、ブックマークがVox.mdのサーバーへ送信されることはありません。Vox.mdは選択したフォルダやObsidian保管庫に標準のMarkdownを書き込みます。アカウントや独自形式のノートデータベースは不要です。

新規ユーザーは15分間の無料文字起こしと10回の送信を利用できます。買い切りで無制限利用を解除できます。
""",
        "テキスト、リンク、ファイル、画像、スキャン、スケッチ、音声をMarkdownへ。文字起こしはデバイス上で完結します。",
        """
新機能：長時間録音で、デバイス上の話者ラベルを利用できます。

改善：ライブアクティビティの操作をより確実にし、長時間録音を安全にしました。

修正：クイックキャプチャとクイック録音のウィジェットがライト／ダーク表示に対応しました。
""",
    ),
    "ko": store_copy(
        """
Vox.md는 Obsidian과 Markdown을 위한 로컬 우선 캡처 앱입니다. 텍스트, 링크, 사진, 파일, 문서 스캔, 스케치, 음성을 알맞은 메모로 보낼 수 있습니다.

캡처 프리셋은 대상, 템플릿, 메타데이터, 첨부 파일, 삽입 위치를 기억합니다. 앱, 공유 시트, 사용자 설정 키보드, 위젯, 단축어 또는 Apple Watch에서 Vox.md를 사용하세요. 보류 중인 전송은 다시 시도할 수 있습니다.

음성 텍스트 변환은 Apple Speech, Whisper 또는 Parakeet을 사용해 기기에서 실행됩니다. 오디오, 전사, 입력한 내용, 파일 경로 및 북마크는 Vox.md 서버로 전송되지 않습니다. Vox.md는 선택한 폴더와 Obsidian 보관함에 표준 Markdown을 기록하며 계정이나 독점 메모 데이터베이스가 필요하지 않습니다.

신규 사용자는 15분의 무료 전사와 10회의 성공적인 전송을 이용할 수 있습니다. 일회성 구매로 무제한 이용을 잠금 해제할 수 있습니다.
""",
        "텍스트, 링크, 파일, 이미지, 스캔, 스케치, 음성을 Markdown으로 캡처하세요. 전사는 기기에서 처리됩니다.",
        """
새로운 기능: 긴 녹음을 위한 기기 내 화자 레이블.

개선: 실시간 현황 제어의 안정성과 긴 녹음의 안전성을 높였습니다.

수정: 빠른 캡처 및 빠른 녹음 위젯이 라이트·다크 모드에 맞게 표시됩니다.
""",
    ),
    "nl-NL": store_copy(
        """
Vox.md is een lokale vastlegapp voor Obsidian en Markdown. Stuur tekst, links, foto’s, bestanden, documentscans, schetsen en spraak naar de juiste notitie.

Vastlegvoorinstellingen onthouden bestemming, sjabloon, metadata, bijlagen en plaatsing. Gebruik Vox.md vanuit de app, het deelmenu, het aangepaste toetsenbord, widgets, Opdrachten of Apple Watch. Wachtende leveringen blijven beschikbaar om opnieuw te proberen.

Spraak-naar-tekst draait op het apparaat met Apple Speech, Whisper of Parakeet. Audio, transcripties, getypte inhoud, bestandspaden en bladwijzers worden niet naar Vox.md-servers gestuurd. Vox.md schrijft standaard-Markdown naar gekozen mappen en Obsidian-kluizen; een account of bedrijfseigen notitiedatabase is niet nodig.

Nieuwe gebruikers krijgen 15 gratis transcriptieminuten en 10 geslaagde leveringen. Een eenmalige aankoop ontgrendelt onbeperkt gebruik.
""",
        "Leg tekst, links, bestanden, afbeeldingen, scans, schetsen en spraak vast als Markdown. Transcriptie blijft op het apparaat.",
        """
Nieuw: Sprekerlabels op het apparaat voor lange opnamen.

Verbeterd: Betrouwbaardere live-activiteitenbediening en veiligere lange opnamen.

Opgelost: Widgets voor Snel vastleggen en Snel opnemen volgen nu de lichte en donkere weergave.
""",
    ),
    "pl": store_copy(
        """
Vox.md to lokalna aplikacja do przechwytywania treści dla Obsidian i Markdown. Wysyłaj tekst, linki, zdjęcia, pliki, skany dokumentów, szkice i głos do właściwej notatki.

Ustawienia przechwytywania zapamiętują miejsce docelowe, szablon, metadane, załączniki i położenie. Korzystaj z Vox.md w aplikacji, arkuszu udostępniania, własnej klawiaturze, widżetach, Skrótach lub na Apple Watch. Oczekujące dostawy można ponowić.

Zamiana mowy na tekst działa na urządzeniu z Apple Speech, Whisper lub Parakeet. Dźwięk, transkrypcje, wpisana treść, ścieżki plików i zakładki nie są wysyłane na serwery Vox.md. Vox.md zapisuje standardowy Markdown w wybranych folderach i magazynach Obsidian; konto ani własnościowa baza notatek nie są wymagane.

Nowi użytkownicy otrzymują 15 bezpłatnych minut transkrypcji i 10 udanych dostaw. Jednorazowy zakup odblokowuje korzystanie bez limitu.
""",
        "Przechwytuj tekst, linki, pliki, obrazy, skany, szkice i głos do Markdown. Transkrypcja pozostaje na urządzeniu.",
        """
Nowość: Etykiety mówców na urządzeniu dla długich nagrań.

Ulepszono: Bardziej niezawodne sterowanie aktywnościami na żywo i bezpieczniejsze długie nagrania.

Naprawiono: Widżety Szybkiego przechwytywania i Szybkiego nagrywania są teraz czytelne w jasnym i ciemnym wyglądzie.
""",
    ),
    "pt-BR": store_copy(
        """
Vox.md é um app de captura local para Obsidian e Markdown. Envie texto, links, fotos, arquivos, digitalizações de documentos, esboços e voz para a nota certa.

As predefinições de captura lembram o destino, o modelo, os metadados, os anexos e a posição. Use o Vox.md pelo app, Folha de Compartilhamento, teclado personalizado, widgets, Atalhos ou Apple Watch. Os envios pendentes continuam disponíveis para nova tentativa.

A conversão de voz em texto é executada no dispositivo com Apple Speech, Whisper ou Parakeet. Áudio, transcrições, conteúdo digitado, caminhos de arquivos e favoritos não são enviados aos servidores do Vox.md. O Vox.md grava Markdown padrão nas pastas e cofres do Obsidian escolhidos; não exige conta nem banco de notas proprietário.

Novos usuários recebem 15 minutos gratuitos de transcrição e 10 envios concluídos. Uma compra única libera o uso ilimitado.
""",
        "Capture texto, links, arquivos, imagens, digitalizações, esboços e voz em Markdown. A transcrição fica no dispositivo.",
        """
Novo: Rótulos de falantes no dispositivo para gravações longas.

Melhorado: Controles de Atividades ao Vivo mais confiáveis e gravações longas mais seguras.

Corrigido: Os widgets Captura Rápida e Gravação Rápida agora acompanham a aparência clara e escura.
""",
    ),
    "ru": store_copy(
        """
Vox.md — локальное приложение для быстрого сохранения материалов в Obsidian и Markdown. Отправляйте текст, ссылки, фотографии, файлы, сканы документов, рисунки и голос в нужную заметку.

Предустановки захвата запоминают место назначения, шаблон, метаданные, вложения и позицию. Используйте Vox.md в приложении, меню «Поделиться», пользовательской клавиатуре, виджетах, Командах или на Apple Watch. Ожидающие отправки можно повторить.

Распознавание речи выполняется на устройстве с Apple Speech, Whisper или Parakeet. Аудио, транскрипции, введённый текст, пути к файлам и закладки не отправляются на серверы Vox.md. Vox.md записывает стандартный Markdown в выбранные папки и хранилища Obsidian; учётная запись и закрытая база заметок не требуются.

Новые пользователи получают 15 бесплатных минут транскрипции и 10 успешных отправок. Одна покупка открывает безлимитное использование.
""",
        "Сохраняйте текст, ссылки, файлы, изображения, сканы, рисунки и голос в Markdown. Транскрипция остаётся на устройстве.",
        """
Новое: Метки говорящих на устройстве для длинных записей.

Улучшено: Более надёжное управление текущей активностью и безопасные длинные записи.

Исправлено: Виджеты быстрого захвата и записи теперь соответствуют светлому и тёмному оформлению.
""",
    ),
    "th": store_copy(
        """
Vox.md เป็นแอปจับข้อมูลแบบทำงานภายในเครื่องสำหรับ Obsidian และ Markdown ส่งข้อความ ลิงก์ รูปภาพ ไฟล์ สแกนเอกสาร ภาพร่าง และเสียงไปยังโน้ตที่ต้องการ

ค่าจับภาพที่ตั้งไว้จะจำปลายทาง เทมเพลต เมทาดาทา ไฟล์แนบ และตำแหน่ง ใช้ Vox.md จากแอป แผ่นแชร์ แป้นพิมพ์แบบกำหนดเอง วิดเจ็ต คำสั่งลัด หรือ Apple Watch รายการที่รอส่งยังคงพร้อมให้ลองใหม่

การแปลงเสียงเป็นข้อความทำงานบนอุปกรณ์ด้วย Apple Speech, Whisper หรือ Parakeet เสียง ข้อความถอดเสียง เนื้อหาที่พิมพ์ เส้นทางไฟล์ และบุ๊กมาร์กจะไม่ถูกส่งไปยังเซิร์ฟเวอร์ Vox.md โดย Vox.md จะเขียน Markdown มาตรฐานลงในโฟลเดอร์และคลัง Obsidian ที่คุณเลือก โดยไม่ต้องมีบัญชีหรือฐานข้อมูลโน้ตเฉพาะ

ผู้ใช้ใหม่ได้รับเวลาถอดเสียงฟรี 15 นาทีและการส่งสำเร็จ 10 ครั้ง การซื้อครั้งเดียวจะปลดล็อกการใช้งานไม่จำกัด
""",
        "จับข้อความ ลิงก์ ไฟล์ รูปภาพ สแกน ภาพร่าง และเสียงเป็น Markdown การถอดเสียงทำงานบนอุปกรณ์",
        """
ใหม่: ป้ายกำกับผู้พูดบนอุปกรณ์สำหรับการบันทึกที่ยาว

ปรับปรุง: การควบคุมกิจกรรมสดเชื่อถือได้มากขึ้นและการบันทึกที่ยาวปลอดภัยขึ้น

แก้ไข: วิดเจ็ตจับภาพด่วนและบันทึกด่วนรองรับรูปลักษณ์สว่างและมืดแล้ว
""",
    ),
    "tr": store_copy(
        """
Vox.md, Obsidian ve Markdown için yerel çalışan bir yakalama uygulamasıdır. Metin, bağlantı, fotoğraf, dosya, belge taraması, çizim ve sesi doğru nota gönderin.

Yakalama Ön Ayarları hedefi, şablonu, meta verileri, ekleri ve yerleşimi hatırlar. Vox.md’yi uygulamadan, Paylaşım Sayfasından, özel klavyeden, araç takımlarından, Kestirmelerden veya Apple Watch’tan kullanın. Bekleyen teslimler yeniden denenebilir.

Konuşmayı metne dönüştürme Apple Speech, Whisper veya Parakeet ile aygıtta çalışır. Ses, transkriptler, yazılan içerik, dosya yolları ve yer imleri Vox.md sunucularına gönderilmez. Vox.md, seçtiğiniz klasörlere ve Obsidian kasalarına standart Markdown yazar; hesap veya özel bir not veritabanı gerekmez.

Yeni kullanıcılar 15 ücretsiz transkripsiyon dakikası ve 10 başarılı teslim alır. Tek seferlik satın alma sınırsız kullanımı açar.
""",
        "Metin, bağlantı, dosya, görsel, tarama, çizim ve sesi Markdown’a aktarın. Transkripsiyon aygıtta kalır.",
        """
Yeni: Uzun kayıtlar için aygıt üzerinde konuşmacı etiketleri.

İyileştirildi: Daha güvenilir Canlı Etkinlik denetimleri ve daha güvenli uzun kayıtlar.

Düzeltildi: Hızlı Yakalama ve Hızlı Kayıt araç takımları artık açık ve koyu görünüme uyuyor.
""",
    ),
    "uk": store_copy(
        """
Vox.md — локальна програма для швидкого збереження матеріалів в Obsidian і Markdown. Надсилайте текст, посилання, фотографії, файли, скани документів, ескізи та голос до потрібної нотатки.

Передустановки захоплення запам’ятовують місце призначення, шаблон, метадані, вкладення та позицію. Використовуйте Vox.md у програмі, меню поширення, власній клавіатурі, віджетах, Швидких командах або на Apple Watch. Відкладені надсилання можна повторити.

Розпізнавання мовлення виконується на пристрої за допомогою Apple Speech, Whisper або Parakeet. Аудіо, транскрипції, введений вміст, шляхи до файлів і закладки не надсилаються на сервери Vox.md. Vox.md записує стандартний Markdown у вибрані папки та сховища Obsidian; обліковий запис і закрита база нотаток не потрібні.

Нові користувачі отримують 15 безплатних хвилин транскрипції та 10 успішних надсилань. Одна покупка відкриває безлімітне використання.
""",
        "Зберігайте текст, посилання, файли, зображення, скани, ескізи й голос у Markdown. Транскрипція залишається на пристрої.",
        """
Нове: Позначки мовців на пристрої для довгих записів.

Поліпшено: Надійніше керування поточною активністю та безпечніші довгі записи.

Виправлено: Віджети швидкого захоплення й запису тепер відповідають світлому та темному оформленню.
""",
    ),
    "vi": store_copy(
        """
Vox.md là ứng dụng ghi nhanh hoạt động cục bộ cho Obsidian và Markdown. Gửi văn bản, liên kết, ảnh, tệp, bản quét tài liệu, bản phác thảo và giọng nói đến đúng ghi chú.

Cấu hình ghi nhanh ghi nhớ đích, mẫu, siêu dữ liệu, tệp đính kèm và vị trí. Dùng Vox.md từ ứng dụng, Bảng chia sẻ, bàn phím tùy chỉnh, tiện ích, Phím tắt hoặc Apple Watch. Nội dung đang chờ gửi vẫn có thể được thử lại.

Chuyển giọng nói thành văn bản chạy trên thiết bị bằng Apple Speech, Whisper hoặc Parakeet. Âm thanh, bản chép lời, nội dung đã nhập, đường dẫn tệp và dấu trang không được gửi đến máy chủ Vox.md. Vox.md ghi Markdown chuẩn vào các thư mục và kho Obsidian bạn chọn; không cần tài khoản hoặc cơ sở dữ liệu ghi chú độc quyền.

Người dùng mới có 15 phút chép lời miễn phí và 10 lần gửi thành công. Một lần mua sẽ mở khóa quyền sử dụng không giới hạn.
""",
        "Ghi văn bản, liên kết, tệp, hình ảnh, bản quét, bản phác thảo và giọng nói vào Markdown. Chép lời chạy trên thiết bị.",
        """
Mới: Nhãn người nói trên thiết bị cho các bản ghi dài.

Cải thiện: Điều khiển Hoạt động trực tiếp đáng tin cậy hơn và bản ghi dài an toàn hơn.

Đã sửa: Tiện ích Ghi nhanh và Ghi âm nhanh giờ phù hợp với giao diện sáng và tối.
""",
    ),
    "zh-Hans": store_copy(
        """
Vox.md 是一款面向 Obsidian 和 Markdown 的本地优先采集应用。将文本、链接、照片、文件、文档扫描、草图和语音发送到合适的笔记。

采集预设会记住目标位置、模板、元数据、附件和插入位置。你可以从应用、共享表单、自定义键盘、小组件、快捷指令或 Apple Watch 使用 Vox.md。待处理的发送内容可随时重试。

语音转文字通过 Apple Speech、Whisper 或 Parakeet 在设备上运行。音频、转录文本、输入内容、文件路径和书签不会发送到 Vox.md 服务器。Vox.md 会将标准 Markdown 写入你选择的文件夹和 Obsidian 仓库；无需帐户或专有笔记数据库。

新用户可获得 15 分钟免费转录和 10 次成功发送。一次性购买即可解锁无限使用。
""",
        "将文本、链接、文件、图像、扫描件、草图和语音采集到 Markdown。转录始终在设备上运行。",
        """
新增：长录音可使用设备端说话人标签。

改进：实时活动控制更加可靠，长录音更加安全。

修复：快速采集和快速录音小组件现已适配浅色与深色外观。
""",
    ),
    "zh-Hant": store_copy(
        """
Vox.md 是一款為 Obsidian 和 Markdown 打造的本機優先擷取應用程式。將文字、連結、照片、檔案、文件掃描、草圖和語音傳送到適合的筆記。

擷取預設會記住目的地、範本、中繼資料、附件和插入位置。你可以從應用程式、分享表單、自訂鍵盤、小工具、捷徑或 Apple Watch 使用 Vox.md。待處理的傳送內容可隨時重試。

語音轉文字透過 Apple Speech、Whisper 或 Parakeet 在裝置上執行。音訊、轉錄文字、輸入內容、檔案路徑和書籤不會傳送到 Vox.md 伺服器。Vox.md 會將標準 Markdown 寫入你選擇的資料夾和 Obsidian 資料庫；不需要帳號或專有筆記資料庫。

新使用者可獲得 15 分鐘免費轉錄和 10 次成功傳送。一次性購買即可解鎖無限使用。
""",
        "將文字、連結、檔案、影像、掃描、草圖和語音擷取至 Markdown。轉錄全程在裝置上執行。",
        """
新增：長時間錄音可使用裝置端說話人標籤。

改進：即時動態控制更加可靠，長時間錄音更加安全。

修正：快速擷取和快速錄音小工具現已適用淺色與深色外觀。
""",
    ),
}

# Region variants intentionally share the same reviewed copy.
METADATA_REVIEWED["es-MX"] = METADATA_REVIEWED["es-ES"]
METADATA_REVIEWED["fr-CA"] = METADATA_REVIEWED["fr-FR"]
