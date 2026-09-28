# Piano: vista ad albero (Tree File View) nel pannello di Double Commander

> **STATO: COMPLETATO** (24/07/2026, branch `treeview`). Tutte le fasi 0-5
> implementate e testate. Extra rispetto al piano: fix navigazione in cartelle
> espanse (ChangePathToChild), fix switch vista Tree→Colonne, dedup selezione
> (CloneSelectedFiles), drop su cartella espansa, watch per-cartella con
> aggiornamenti live e ri-espansione dopo i reload.

Obiettivo: aggiungere un **quarto tipo di vista** del pannello file (accanto a Colonne,
Breve, Miniature) con **cartelle espandibili inline** stile file manager GTK
(Nemo/Nautilus "vista elenco"): triangolo expander, figli indentati sotto il padre,
colonne Nome/Dimensione/Data ancora funzionanti.

Non realizzabile come plugin: l'API plugin (WCX/WDX/WFX/WLX/DSX) non tocca il
rendering del pannello. Si lavora nel sorgente (`~/Downloads/doublecmd_src`,
branch master 1.3.0 alpha, lo stesso del binario in produzione).

---

## 1. Architettura esistente (fatti verificati nel sorgente)

### Gerarchia delle viste (`src/fileviews/`)

```
TFileView                    (ufileview.pas)      — modello, worker, history, FlatView
└─ TOrderedFileView          (uorderedfileview.pas) — lista ordinata, quick search
   └─ TFileViewWithMainCtrl  (ufileviewwithmainctrl.pas) — mouse/tastiera/drag&drop
      ├─ TColumnsFileView    (ucolumnsfileview.pas) — griglia a colonne (TDrawGrid custom)
      └─ TFileViewWithGrid   (ufileviewwithgrid.pas)
         ├─ TBriefFileView   (ubrieffileview.pas)
         └─ TThumbFileView   (uthumbfileview.pas)
```

### Punti di aggancio

| Cosa | Dove |
|---|---|
| Factory viste da config | `TfrmMain.CreateFileView` — `src/fmain.pas:5203` (mappa `'columns'`/`'brief'`/`'thumbnails'` → classe; commento upstream: "should be changed to a separate TFileView factory") |
| Comandi switch vista | `src/umaincommands.pas:2262-2374` — `cm_BriefView`/`cm_ColumnsView`/`cm_ThumbnailsView`; ognuno crea la vista col costruttore-clone `TXxxFileView.Create(Page, OldView)` |
| Azioni + menu Mostra | `src/fmain.lfm:2254-2272` (`actBriefView`, `actColumnsView`, `actThumbnailsView`) e voci menu a `src/fmain.lfm:1365-1371` |
| Salvataggio tipo vista nelle schede | `SaveConfiguration(AConfig, ANode, ...)` override in ogni vista (es. `ucolumnsfileview.pas:303`) — scrive il tipo nel session XML |
| Modello dati | `TDisplayFile` (`src/udisplayfile.pas:24`): wrappa `TFile` (`FSFile`), `IconID`, `DisplayStrings` (cache testi celle). La lista pannello è **piatta**, una directory alla volta |
| Costruzione lista (async) | `TFileListBuilder` (`src/fileviews/ufileviewworker.pas:82`) in un thread; enumera via `FileSource.CreateListOperation`, filtra, ordina |
| Precedente utile: FlatView | `TFileView.FFlatView` (`ufileview.pas:231`, setter riga 3416) passato al builder (`ufileviewworker.pas:464` → `FListOperation.FlatView`): lista **ricorsiva ma piatta**. Ha già risolto metà dei problemi (file con path ≠ CurrentPath nelle operazioni) |
| Rendering prima colonna | `ucolumnsfileview.pas:1564` `DrawIconCell` dentro `DrawCell` (riga 1896): disegna icona + testo — qui vanno indent ed expander |
| Tastiera | `DoHandleKeyDown` override per vista (`ucolumnsfileview.pas:167`) |

### Vincolo chiave del modello

`ufileview.pas:159`: *"when not in FlatView Mode, FileName only used as Key for
FHashedNames"* — la lista usa il **nome file come chiave hash**. Con l'albero ci
sono file omonimi in directory diverse: bisogna fare come FlatView e usare il
**path relativo** come chiave.

---

## 2. Decisioni di design

1. **Classe base**: `TTreeFileView = class(TColumnsFileView)` in una nuova unit
   `utreefileview.pas`. Eredita gratis: colonne, header, colori, sorting, quick
   search, selezione, drag&drop. Scartato partire da `TFileViewWithGrid` (perdi
   le colonne) o da zero (mesi di lavoro).

2. **Livello di indentazione**: NON aggiungere campi a `TDisplayFile` (unit
   condivisa da tutte le viste — modifica invasiva). Il livello si calcola dal
   path: `Livello = numero di PathDelim in (FSFile.Path - CurrentPath)`. Zero
   modifiche a `udisplayfile.pas`.

3. **Stato espansione**: `FExpandedPaths: TStringHashListUtf8` (set di path
   assoluti espansi) come campo di `TTreeFileView`. Si azzera al cambio di
   directory. Persistenza tra sessioni: fase futura, non ora.

4. **Espansione = inserimento incrementale, non rebuild**. All'espansione di
   una dir: enumerazione **sincrona** della sola dir espansa
   (`FileSource.CreateListOperation` con `Execute` diretto, come fa già
   `fFindDlg`), creazione dei `TDisplayFile` figli, sort dei soli fratelli con
   `TDisplayFileSorter`, inserimento in `FFiles` subito dopo il padre. Al
   collasso: rimozione di tutte le righe il cui `FSFile.Path` ha il path della
   dir come prefisso (chiude anche i sotto-alberi). Il rebuild totale via worker
   (stile FlatView) è scartato: lento e perde lo stato di espansione a ogni
   refresh.

5. **Sorting gerarchico**: al cambio di colonna di ordinamento non basta
   riordinare la lista piatta (mescolerebbe i livelli). Metodo
   `ResortTree`: raggruppa le righe per directory padre, ordina ogni gruppo di
   fratelli, ricompone la lista in DFS (padre → figli ricorsivamente).

6. **Rendering** (override del disegno prima colonna):
   - indent: `Livello × (gIconsSize + margine)` px, scalato col DPI;
   - expander: triangolo pieno ▼/▶ disegnato con `Canvas.Polygon` (niente
     theming di sistema: su Qt6/Wayland `tvoThemedDraw` è proprio la causa del
     bug delle scritte sdoppiate già fixato — evitarlo del tutto);
   - poi icona e testo come oggi. Colonne Dimensione/Data invariate.

7. **Input**:
   - click sul triangolo → toggle espansione (hit-test sul rettangolo expander);
   - `Destra` su dir chiusa → espandi; su dir aperta → vai al primo figlio;
   - `Sinistra` su dir aperta → collassa; altrimenti → salta al padre;
   - `Invio`/doppio click su dir → navigazione normale DC (cambia directory),
     comportamento invariato;
   - `Ctrl+Sinistra/Destra` restano ai comandi DC esistenti (non toccarli).

8. **Refresh/watcher**: `TFileSystemWatcher` osserva solo `CurrentPath`. Fase
   iniziale: le dir espanse NON sono osservate; un refresh manuale (`Ctrl+R`)
   ri-espande ciò che è in `FExpandedPaths`. Watch multipli: fase futura.

9. **FlatView e TreeView si escludono**: entrando nella vista albero forzare
   `FlatView := False` (e viceversa il toggle flat in vista albero collassa
   tutto prima).

---

## 3. File da creare/modificare

| # | File | Intervento |
|---|---|---|
| 1 | `src/fileviews/utreefileview.pas` | **NUOVO** (~600-800 righe): `TTreeFileView`, espansione/collasso, resort gerarchico, rendering expander+indent, tastiera, `SaveConfiguration` (scrive tipo `'tree'` + eventualmente lista path espansi), costruttori (i 3 overload come le altre viste: da config, clone da vista esistente, da filesource) |
| 2 | `src/fmain.pas` | `CreateFileView` riga ~5216: ramo `else if sType = 'tree'` → `TTreeFileView.Create(...)`; `uses` della nuova unit |
| 3 | `src/umaincommands.pas` | Nuovo `cm_TreeView(Params)` sul modello esatto di `cm_ThumbnailsView` (riga 2374): dichiarazione in `published`, implementazione con clone della vista attiva; `uses utreefileview` |
| 4 | `src/fmain.lfm` | `actTreeView: TAction` (dopo riga 2272) + voce nel menu Mostra (dopo riga 1371) |
| 5 | `src/fmain.pas` | Handler `actExecute` già generico sui `cm_*`: verificare che l'action venga instradata (le action DC chiamano il commando omonimo per nome — nessun codice extra se la convenzione regge) |
| 6 | `src/uglobs.pas` | Solo se si vuole un hotkey di default (es. `Ctrl+Shift+F1`); altrimenti l'utente lo assegna da Opzioni → Tasti |
| 7 | `po/doublecmd.po` + `po/doublecmd.it.po` | Stringa della voce di menu (`Vista ad al&bero`) |
| 8 | `src/doublecmd.lpi` | Nessuna modifica attesa: `fileviews/` è già nel search path; la unit entra via `uses` |

---

## 4. Fasi di implementazione (ognuna compila e si prova)

**Fase 0 — Scheletro** *(mezza giornata)*
`TTreeFileView` vuota che eredita tutto da `TColumnsFileView`; `cm_TreeView`,
action, menu, factory, `SaveConfiguration` con tipo `'tree'`.
✔ Verifica: si attiva dal menu Mostra, si comporta come la vista colonne,
chiudi/riapri DC e la scheda ricorda il tipo `tree` (controllo in
`~/.config/doublecmd/session .xml` a DC chiuso — ricorda: DC risovrascrive la
config alla chiusura).

**Fase 1 — Expander visivo** *(1 giorno)*
Override del disegno prima colonna: indent (per ora sempre 0) + triangolo su
ogni directory; hit-test del click con toggle su `FExpandedPaths` (solo stato,
ancora nessun figlio); triangolo che ruota.
✔ Verifica: screenshot, click preciso sul triangolo vs click sul nome (il nome
deve ancora selezionare/navigare), HiDPI col scaling Hyprland.

**Fase 2 — Espansione dati** *(2-3 giorni, il cuore)*
Enumerazione sincrona della dir espansa, creazione `TDisplayFile` figli con
icone (`PixMapManager.GetIconByFile`), inserimento post-padre, collasso per
prefisso, chiave hash = path relativo.
✔ Verifica: espandi dir grande (`/usr/lib`), dir vuota, dir senza permessi
(niente crash, niente triangolo o triangolo che non apre), espansione annidata
3+ livelli, collasso del nonno chiude tutto, cambio directory azzera lo stato.

**Fase 3 — Sorting gerarchico + tastiera** *(1-2 giorni)*
`ResortTree` su click colonna e su inversione ordine; frecce Destra/Sinistra
come da design §2.7.
✔ Verifica: ordina per dimensione con 3 livelli aperti → i figli restano sotto
il padre; navigazione completa solo da tastiera.

**Fase 4 — Operazioni file su albero** *(1-2 giorni, secondo punto critico)*
Copy/Move/Delete/Rename/Proprietà/F3/F4 con cursore o selezione su righe di
livelli diversi. Cercare nel sorgente tutti i punti in cui le operazioni
assumono `Path = CurrentPath` — il riferimento è **come li gestisce FlatView**
(`grep -n FlatView src/fileviews/ufileview.pas src/umaincommands.pas`): dove
c'è un ramo FlatView, l'albero deve prendere lo stesso ramo (criterio:
`FFlatView or IsTreeView` → probabilmente conviene un metodo virtuale
`HasMixedPaths: Boolean` in `TFileView`, `True` nella tree view).
✔ Verifica: F5 di un file dentro una dir espansa → destinazione giusta nel
pannello opposto; F8 di una dir espansa; rinomina inline (Shift+F6) di un
figlio; selezione con Spazio mista tra livelli + F5.

**Fase 5 — Rifiniture ed edge case** *(1 giorno)*
Refresh `Ctrl+R` che ri-espande da `FExpandedPaths` (path spariti → rimossi dal
set); esclusione mutua con FlatView; quick search (lettere) sulla lista mista;
click destro/menu contestuale su un figlio; archivi e WFX: **primo rilascio
solo filesystem reale** — su file source non-filesystem il triangolo non si
disegna (`FileSource.IsClass(TFileSystemFileSource)`).
✔ Verifica: checklist completa delle fasi precedenti ripetuta + una giornata
d'uso reale.

**Build a ogni fase**: `cd ~/Downloads/doublecmd_src && lcl=qt6 ./build.sh doublecmd`
poi test col binario locale `./doublecmd` (attenzione: DC è single-instance —
chiudere quello in produzione prima). Deploy: copia del solo binario su
`/opt/doublecmd/doublecmd` (backup `doublecmd.orig` già presente).

---

## 5. Rischi principali

1. **Operazioni file** (fase 4): è qui che un errore costa dati. Mitigazione:
   seguire pedissequamente i rami FlatView già collaudati upstream; testare
   copy/delete prima in una sandbox (`/tmp/tree-test`).
2. **Chiavi hash per nome** (`ufileview.pas:159`): omonimi su livelli diversi
   → collisioni. Mitigazione: chiave = path relativo fin dalla fase 2.
3. **Worker asincrono**: il reload del pannello (builder in thread) ricostruisce
   `FFiles` e cancellerebbe le righe espanse. Mitigazione: hook a fine
   `SetFileList` che ri-applica `FExpandedPaths` (è il punto più delicato da
   trovare: cercare `DoFileListChanged` / `SetFilelist` in `ufileview.pas`).
4. **Qt6/Wayland painting**: niente `tvoThemedDraw`/theming di sistema per
   l'expander (lezione del bug #3000): solo `Canvas.Polygon`.
5. **Divergenza da upstream**: ~800-1200 righe locali da ri-applicare a ogni
   aggiornamento del sorgente. Mitigazione: tenere tutto in commit dedicati su
   un branch locale (es. `treeview`) e fare rebase; valutare proposta upstream
   (è una feature richiesta da anni nel tracker DC).

## 6. Stima complessiva

- **~800-1200 righe** nuove, quasi tutte in `utreefileview.pas`
- **6-9 giorni** di lavoro effettivo distribuiti sulle 6 fasi
- Rischio concentrato in fase 2 (modello) e fase 4 (operazioni file)
