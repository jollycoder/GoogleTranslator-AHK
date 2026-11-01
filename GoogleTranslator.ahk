#Requires AutoHotkey v2.0
#SingleInstance Force
;@Ahk2Exe-SetName GoogleTranslator
;@Ahk2Exe-SetDescription Google Translate client for Windows
;@Ahk2Exe-SetVersion 1.0.0
;@Ahk2Exe-SetOrigFilename GoogleTranslator.exe
; The base path is relative to the compiler folder (AutoHotkey\Compiler).
;@Ahk2Exe-Base ..\v2\AutoHotkey64.exe
; The compiled program carries the icon in its resources; the script takes it
; from the icon file. GUI windows created later use the same icon.
;@Ahk2Exe-SetMainIcon Resources\GoogleTranslator.ico
if !A_IsCompiled {
    TraySetIcon(AppIconSource.File)
}
A_IconTip := 'Google Translate ' . Config.VERSION

; Provides ISO 15924 script lists for text and Windows locale names.
; Common and inherited characters are deliberately ignored: punctuation and
; digits must not influence the translation direction.
class WindowsScriptResolver
{
    static LOCALE_SSCRIPTS := 0x6C
    static LOCALE_NAME_MAX_LENGTH := 85
    static localeScriptCache := Map()

    static Resolve(subjectKind, value) {
        switch subjectKind {
            case 'text':
                return this.GetTextScripts(value)
            case 'locale':
                return this.GetLocaleScripts(value)
            default:
                throw ValueError('Unknown script resolver subject: ' . subjectKind)
        }
    }

    static GetTextScripts(sourceText) {
        if sourceText == '' {
            return ''
        }

        requiredChars := DllCall('Kernel32\GetStringScripts',
                                 'UInt', 0, 'WStr', sourceText, 'Int', -1,
                                 'Ptr', 0, 'Int', 0, 'Int')
        if requiredChars <= 1 {
            return ''
        }

        scriptBuffer := Buffer(requiredChars * 2, 0)
        writtenChars := DllCall('Kernel32\GetStringScripts',
                                'UInt', 0, 'WStr', sourceText, 'Int', -1,
                                'Ptr', scriptBuffer, 'Int', requiredChars, 'Int')
        return writtenChars > 1 ? StrGet(scriptBuffer.Ptr, 'UTF-16') : ''
    }

    static GetLocaleScripts(languageCode) {
        normalizedCode := this._NormalizeLanguageCode(languageCode)
        if normalizedCode == '' {
            return ''
        }

        cacheKey := StrLower(normalizedCode)
        if this.localeScriptCache.Has(cacheKey) {
            return this.localeScriptCache[cacheKey]
        }

        localeName := this._ResolveLocaleName(normalizedCode)
        if localeName == '' {
            this.localeScriptCache[cacheKey] := ''
            return ''
        }

        requiredChars := DllCall('Kernel32\GetLocaleInfoEx',
                                 'WStr', localeName, 'UInt', this.LOCALE_SSCRIPTS,
                                 'Ptr', 0, 'Int', 0, 'Int')
        if requiredChars <= 1 {
            this.localeScriptCache[cacheKey] := ''
            return ''
        }

        scriptBuffer := Buffer(requiredChars * 2, 0)
        writtenChars := DllCall('Kernel32\GetLocaleInfoEx',
                                'WStr', localeName, 'UInt', this.LOCALE_SSCRIPTS,
                                'Ptr', scriptBuffer, 'Int', requiredChars, 'Int')
        scripts := writtenChars > 1 ? StrGet(scriptBuffer.Ptr, 'UTF-16') : ''
        this.localeScriptCache[cacheKey] := scripts
        return scripts
    }

    static _ResolveLocaleName(languageCode) {
        localeNameBuffer := Buffer(this.LOCALE_NAME_MAX_LENGTH * 2, 0)
        resolvedChars := DllCall('Kernel32\ResolveLocaleName',
                                 'WStr', languageCode, 'Ptr', localeNameBuffer,
                                 'Int', this.LOCALE_NAME_MAX_LENGTH, 'Int')
        ; Unknown names can resolve to an empty invariant locale. It must not be
        ; mistaken for a real language with a Latin script.
        return resolvedChars > 1 ? StrGet(localeNameBuffer.Ptr, 'UTF-16') : ''
    }

    static _NormalizeLanguageCode(languageCode) {
        normalizedCode := StrReplace(Trim(languageCode), '_', '-')
        switch StrLower(normalizedCode) {
            case '', 'auto':
                return ''
            case 'iw':
                return 'he'
            case 'jw':
                return 'jv'
            default:
                return normalizedCode
        }
    }
}

; Collects ordered Windows language preferences without changing the active
; keyboard layout or any system setting.
class WindowsLanguagePreferences
{
    static MUI_LANGUAGE_NAME := 0x8
    static LOCALE_NAME_MAX_LENGTH := 85

    static GetPreferences() {
        preferredTags := [], fallbackTags := []
        try preferredTags := this.GetUserLanguageTags()
        try this._AppendPreferredUiLanguages(fallbackTags)
        try this._AppendDefaultLocale(fallbackTags)
        try this._AppendInputLocale(fallbackTags)
        return { preferredTags: preferredTags, fallbackTags: fallbackTags }
    }

    ; GlobalizationPreferences.Languages includes the user's ordered language
    ; list even when those languages have no installed Windows UI pack.
    static GetUserLanguageTags() {
        initResult := DllCall('Combase\RoInitialize', 'UInt', 0, 'Int')
        ; RPC_E_CHANGED_MODE means this thread already uses another apartment.
        if initResult < 0 && initResult != -2147417850 {
            throw Error('Unable to initialize Windows language preferences')
        }
        classNameHandle := preferencesFactory := languageVector := 0
        try {
            className := 'Windows.System.UserProfile.GlobalizationPreferences'
            if DllCall('Combase\WindowsCreateString', 'WStr', className,
                       'UInt', StrLen(className), 'PtrP', &classNameHandle, 'Int') < 0 {
                throw Error('Unable to create the language preferences class name')
            }
            interfaceId := Buffer(16, 0)
            DllCall('Ole32\CLSIDFromString',
                    'WStr', '{01BF4326-ED37-4E96-B0E9-C1340D1EA158}',
                    'Ptr', interfaceId, 'Int')
            if DllCall('Combase\RoGetActivationFactory', 'Ptr', classNameHandle,
                       'Ptr', interfaceId, 'PtrP', &preferencesFactory, 'Int') < 0 {
                throw Error('Windows language preferences are unavailable')
            }
            ; IGlobalizationPreferencesStatics::get_Languages, followed by
            ; IVectorView<HSTRING>::get_Size and GetAt (Windows SDK ABI).
            ComCall(9, preferencesFactory, 'PtrP', &languageVector)
            languageCount := 0
            ComCall(7, languageVector, 'UIntP', &languageCount)
            languageTags := []
            Loop languageCount {
                languageHandle := 0
                try {
                    ComCall(6, languageVector, 'UInt', A_Index - 1, 'PtrP', &languageHandle)
                    characterCount := 0
                    textPointer := DllCall('Combase\WindowsGetStringRawBuffer',
                                          'Ptr', languageHandle, 'UIntP', &characterCount, 'Ptr')
                    if textPointer && characterCount {
                        this._AppendUnique(languageTags,
                                           StrGet(textPointer, characterCount, 'UTF-16'))
                    }
                } finally {
                    if languageHandle
                        DllCall('Combase\WindowsDeleteString', 'Ptr', languageHandle, 'Int')
                }
            }
            return languageTags
        } finally {
            if languageVector
                ObjRelease(languageVector)
            if preferencesFactory
                ObjRelease(preferencesFactory)
            if classNameHandle
                DllCall('Combase\WindowsDeleteString', 'Ptr', classNameHandle, 'Int')
            if initResult >= 0
                DllCall('Combase\RoUninitialize')
        }
    }

    static _AppendPreferredUiLanguages(languageTags) {
        languageCount := requiredChars := 0
        if !DllCall('Kernel32\GetUserPreferredUILanguages',
                    'UInt', this.MUI_LANGUAGE_NAME, 'UIntP', &languageCount,
                    'Ptr', 0, 'UIntP', &requiredChars, 'Int') || requiredChars < 2 {
            return
        }

        languagesBuffer := Buffer(requiredChars * 2, 0)
        if !DllCall('Kernel32\GetUserPreferredUILanguages',
                    'UInt', this.MUI_LANGUAGE_NAME, 'UIntP', &languageCount,
                    'Ptr', languagesBuffer, 'UIntP', &requiredChars, 'Int') {
            return
        }

        byteOffset := 0
        Loop languageCount {
            languageTag := StrGet(languagesBuffer.Ptr + byteOffset, 'UTF-16')
            if languageTag == ''
                break
            this._AppendUnique(languageTags, languageTag)
            byteOffset += (StrLen(languageTag) + 1) * 2
        }
    }

    static _AppendDefaultLocale(languageTags) {
        localeNameBuffer := Buffer(this.LOCALE_NAME_MAX_LENGTH * 2, 0)
        writtenChars := DllCall('Kernel32\GetUserDefaultLocaleName',
                                'Ptr', localeNameBuffer,
                                'Int', this.LOCALE_NAME_MAX_LENGTH, 'Int')
        if writtenChars > 1
            this._AppendUnique(languageTags, StrGet(localeNameBuffer.Ptr, 'UTF-16'))
    }

    static _AppendInputLocale(languageTags) {
        keyboardLayout := DllCall('User32\GetKeyboardLayout', 'UInt', 0, 'Ptr')
        languageId := keyboardLayout & 0xFFFF
        if !languageId
            return

        localeNameBuffer := Buffer(this.LOCALE_NAME_MAX_LENGTH * 2, 0)
        writtenChars := DllCall('Kernel32\LCIDToLocaleName',
                                'UInt', languageId, 'Ptr', localeNameBuffer,
                                'Int', this.LOCALE_NAME_MAX_LENGTH, 'UInt', 0, 'Int')
        if writtenChars > 1
            this._AppendUnique(languageTags, StrGet(localeNameBuffer.Ptr, 'UTF-16'))
    }

    static _AppendUnique(languageTags, languageTag) {
        for existingTag in languageTags {
            if existingTag = languageTag
                return
        }
        languageTags.Push(languageTag)
    }
}

; Maps Windows language tags to Google codes and chooses a supported pair.
; Only two explicit user preferences justify auto-save. Other Windows hints
; and the English fallback may prefill setup, but require confirmation.
class LanguagePairAdvisor
{
    static Suggest(preferredTags, supportedLanguages, fallbackTags := unset,
                   savedNativeLanguage := '', savedOppositeLanguage := '') {
        preferredLanguages := this._SupportedCodes(preferredTags, supportedLanguages)
        candidates := preferredLanguages.Clone()
        if IsSet(fallbackTags) {
            for supportedCode in this._SupportedCodes(fallbackTags, supportedLanguages)
                this._AppendUnique(candidates, supportedCode)
        }

        nativeLanguage := this.FindSupportedCode(savedNativeLanguage, supportedLanguages)
        oppositeLanguage := this.FindSupportedCode(savedOppositeLanguage, supportedLanguages)
        if this._CodesEqual(nativeLanguage, oppositeLanguage)
            oppositeLanguage := ''
        for candidateCode in candidates {
            if nativeLanguage == '' && !this._CodesEqual(candidateCode, oppositeLanguage)
                nativeLanguage := candidateCode
            if oppositeLanguage == '' && !this._CodesEqual(candidateCode, nativeLanguage)
                oppositeLanguage := candidateCode
        }
        if oppositeLanguage == '' && nativeLanguage != ''
                && !this._CodesEqual(nativeLanguage, 'en') {
            oppositeLanguage := this.FindSupportedCode('en', supportedLanguages)
        }

        return {
            nativeLanguage: nativeLanguage,
            oppositeLanguage: oppositeLanguage,
            canAutoSave: savedNativeLanguage == '' && savedOppositeLanguage == ''
                && preferredLanguages.Length > 1
                && this.IsValidPair(nativeLanguage, oppositeLanguage)
        }
    }

    static _SupportedCodes(languageTags, supportedLanguages) {
        languageCodes := []
        for languageTag in languageTags
            this._AppendUnique(languageCodes, this.FindSupportedCode(languageTag, supportedLanguages))
        return languageCodes
    }

    ; Included regression scripts cannot ask the user for input. Complete their
    ; transient pair deterministically, without persisting it or affecting the
    ; primary script's first-run policy.
    static CompletePairForNonInteractive(nativeLanguage, oppositeLanguage,
                                         supportedLanguages) {
        if nativeLanguage == '' {
            nativeLanguage := this.FindSupportedCode('en', supportedLanguages)
        }
        if nativeLanguage == '' {
            for availableCode in supportedLanguages {
                nativeLanguage := availableCode
                break
            }
        }

        if oppositeLanguage == '' || this._CodesEqual(nativeLanguage, oppositeLanguage) {
            oppositeLanguage := ''
            for availableCode in supportedLanguages {
                if !this._CodesEqual(availableCode, nativeLanguage) {
                    oppositeLanguage := availableCode
                    break
                }
            }
        }
        return {
            nativeLanguage: nativeLanguage,
            oppositeLanguage: oppositeLanguage
        }
    }

    static NormalizeGoogleCode(languageTag) {
        normalizedTag := StrLower(StrReplace(Trim(languageTag), '_', '-'))
        if normalizedTag == ''
            return ''

        if normalizedTag ~= '^zh(?:-|$)' {
            if normalizedTag ~= '(?:^|-)hant(?:-|$)'
                return 'zh-TW'
            if normalizedTag ~= '(?:^|-)hans(?:-|$)'
                return 'zh-CN'
            if normalizedTag ~= '-(?:tw|hk|mo)(?:-|$)'
                return 'zh-TW'
            return 'zh-CN'
        }

        baseCode := RegExReplace(normalizedTag, '-.*$')
        switch baseCode {
            case 'he', 'iw':
                return 'iw'
            case 'jv', 'jw':
                return 'jw'
            case 'fil', 'tl':
                return 'tl'
            case 'nb', 'no':
                return 'no'
            case 'mni':
                return 'mni-Mtei'
            default:
                return baseCode
        }
    }

    static FindSupportedCode(languageCode, supportedLanguages) {
        languageCode := StrReplace(Trim(languageCode), '_', '-')
        if languageCode == '' || languageCode = 'auto'
            return ''
        ; Preserve supported regional/script variants before reducing the tag.
        normalizedCode := this.NormalizeGoogleCode(languageCode)
        for candidateCode in [languageCode, normalizedCode] {
            for supportedCode in supportedLanguages {
                if supportedCode = candidateCode
                    return supportedCode
            }
        }

        alternateCode := ''
        switch StrLower(normalizedCode) {
            case 'iw':
                alternateCode := 'he'
            case 'he':
                alternateCode := 'iw'
            case 'jw':
                alternateCode := 'jv'
            case 'jv':
                alternateCode := 'jw'
            case 'tl':
                alternateCode := 'fil'
            case 'no':
                alternateCode := 'nb'
        }
        if alternateCode != '' {
            for supportedCode in supportedLanguages {
                if supportedCode = alternateCode
                    return supportedCode
            }
        }
        return ''
    }

    static IsValidPair(nativeLanguage, oppositeLanguage) {
        return nativeLanguage != '' && oppositeLanguage != ''
            && !this._CodesEqual(nativeLanguage, oppositeLanguage)
    }

    static _CodesEqual(firstCode, secondCode) {
        return StrLower(firstCode) == StrLower(secondCode)
    }

    static _AppendUnique(languageCodes, languageCode) {
        if languageCode == ''
            return
        for existingCode in languageCodes {
            if this._CodesEqual(existingCode, languageCode)
                return
        }
        languageCodes.Push(languageCode)
    }
}

; Conservative, pair-aware evidence for languages which share a script. Letter
; sets follow the core CLDR exemplar alphabets. The small word lists are
; curated hints, not complete dictionaries; known ambiguous words are omitted.
class StrongLanguageMarkers
{
    static profiles := Map(
        'ru', {
            letters: 'абвгдеёжзийклмнопрстуфхцчшщъыьэюя',
            words: ['это', 'что', 'как', 'нет', 'привет', 'спасибо', 'работа', 'язык', 'русский']
        },
        'uk', {
            letters: 'абвгґдеєжзиіїйклмнопрстуфхцчшщьюя',
            words: ['це', 'що', 'як', 'ні', 'привіт', 'дякую', 'робота', 'мова', 'український']
        },
        'be', {
            letters: 'абвгдеёжзійклмнопрстуўфхцчшыьэюя',
            words: ['гэта', 'што', 'як', 'прывітанне', 'дзякуй', 'праца', 'мова', 'беларускі']
        },
        'en', {
            letters: 'abcdefghijklmnopqrstuvwxyz',
            words: ['the', 'this', 'that', 'with', 'your', 'hello', 'thanks', 'please', 'work', 'language']
        },
        'de', {
            letters: 'abcdefghijklmnopqrstuvwxyzäöüß',
            words: ['der', 'das', 'und', 'nicht', 'für', 'ich', 'hallo', 'danke', 'bitte', 'arbeit', 'sprache', 'über']
        },
        'fr', {
            letters: 'abcdefghijklmnopqrstuvwxyzàâæçéèêëîïôœùûüÿ',
            words: ['bonjour', 'merci', 'avec', 'vous', 'nous', 'une', 'les', 'des', 'travail', 'langue', 'être', 'français']
        }
    )

    ; A veto for modern East Slavic alphabets, never proof of a language.
    ; Ignore punctuation, digits and combining stress marks. U+02BC is a
    ; modifier letter in Unicode, but an apostrophe in both Ukrainian and
    ; Belarusian: allow it without treating it as a language marker.
    static IsAlphabetCompatible(sourceText, languageCode) {
        baseCode := this._BaseLanguageCode(languageCode)
        if baseCode != 'ru' && baseCode != 'uk' && baseCode != 'be'
            return true
        alphabetLetters := this.profiles[baseCode].letters
        return RegExMatch(sourceText, 'i)[' . alphabetLetters . ']')
            && !RegExMatch(sourceText, 'i)(?![' . alphabetLetters . 'ʼ])\p{L}')
    }

    static Resolve(sourceText, nativeLanguage, oppositeLanguage) {
        nativeCode := this._BaseLanguageCode(nativeLanguage)
        oppositeCode := this._BaseLanguageCode(oppositeLanguage)
        if nativeCode == oppositeCode
            return ''
        if !this.profiles.Has(nativeCode) || !this.profiles.Has(oppositeCode)
            return ''

        nativeProfile := this.profiles[nativeCode]
        oppositeProfile := this.profiles[oppositeCode]
        hasNativeMarker := this._HasExclusiveMarker(sourceText, nativeProfile, oppositeProfile)
        hasOppositeMarker := this._HasExclusiveMarker(sourceText, oppositeProfile, nativeProfile)

        if hasNativeMarker && hasOppositeMarker
            return 'conflict'
        if hasNativeMarker
            return PairLanguageDetector.SIDE_NATIVE
        if hasOppositeMarker
            return PairLanguageDetector.SIDE_OPPOSITE
        return ''
    }

    static _HasExclusiveMarker(sourceText, languageProfile, otherProfile) {
        ; InStr ignores case only for A-Z, while the profiles also contain
        ; non-ASCII letters: compare lowercase text with lowercase letters.
        lowerText := StrLower(sourceText)
        for markerLetter in StrSplit(languageProfile.letters) {
            if !InStr(otherProfile.letters, markerLetter, true)
                    && InStr(lowerText, markerLetter, true) {
                return true
            }
        }

        for markerWord in languageProfile.words {
            if this._ContainsWord(otherProfile.words, markerWord)
                continue
            if RegExMatch(sourceText, 'i)(?<!\p{L})\Q' . markerWord . '\E(?!\p{L})')
                return true
        }
        return false
    }

    static _ContainsWord(words, soughtWord) {
        for candidateWord in words {
            if candidateWord = soughtWord
                return true
        }
        return false
    }

    static _BaseLanguageCode(languageCode) {
        normalizedCode := StrLower(StrReplace(Trim(languageCode), '_', '-'))
        separatorPosition := InStr(normalizedCode, '-')
        return separatorPosition ? SubStr(normalizedCode, 1, separatorPosition - 1) : normalizedCode
    }
}

; Google can confuse short words written in closely related languages. When
; the pair detector has already selected one side, prefer that configured
; language over another East Slavic label returned by auto-detection. Outside
; this narrow group, without a direction hint, or when the text contradicts
; the preferred alphabet, preserve Google's result.
class DetectedLanguageCorrection
{
    static eastSlavicLanguages := Map('ru', true, 'uk', true, 'be', true)

    static Resolve(detectedLanguage, nativeLanguage, oppositeLanguage, directionSide, sourceText) {
        switch directionSide {
            case 'native':
                preferredLanguage := nativeLanguage
            case 'opposite':
                preferredLanguage := oppositeLanguage
            default:
                return detectedLanguage
        }

        preferredCode := this._BaseLanguageCode(preferredLanguage)
        detectedCode := this._BaseLanguageCode(detectedLanguage)
        if this.eastSlavicLanguages.Has(preferredCode)
                && this.eastSlavicLanguages.Has(detectedCode)
                && StrongLanguageMarkers.IsAlphabetCompatible(sourceText, preferredLanguage) {
            return preferredLanguage
        }
        return detectedLanguage
    }

    static _BaseLanguageCode(languageCode) {
        normalizedCode := StrLower(StrReplace(Trim(languageCode), '_', '-'))
        separatorPosition := InStr(normalizedCode, '-')
        return separatorPosition ? SubStr(normalizedCode, 1, separatorPosition - 1) : normalizedCode
    }
}

; Resolves which side of the configured language pair a text resembles.
; It deliberately does not claim to know the exact source language: the
; translation request must remain free to use `sl=auto`.
class PairLanguageDetector
{
    static SIDE_NATIVE   := 'native'
    static SIDE_OPPOSITE := 'opposite'
    static SIDE_UNKNOWN  := 'unknown'

    __New(nativeLanguage, oppositeLanguage, scriptResolver := unset, markerResolver := unset) {
        if !IsSet(scriptResolver) {
            scriptResolver := ResolveWindowsScripts
        }
        if !IsSet(markerResolver) {
            markerResolver := ResolveStrongLanguageMarkers
        }
        if nativeLanguage == '' || oppositeLanguage == '' {
            throw ValueError('Both language codes must be specified.')
        }
        if nativeLanguage == oppositeLanguage {
            throw ValueError('The language pair must contain two different languages.')
        }
        if scriptResolver != '' && !(scriptResolver is Func) {
            throw TypeError('scriptResolver must be a function or an empty string.')
        }
        if markerResolver != '' && !(markerResolver is Func) {
            throw TypeError('markerResolver must be a function or an empty string.')
        }

        this.nativeLanguage := nativeLanguage
        this.oppositeLanguage := oppositeLanguage
        this.scriptResolver := scriptResolver
        this.markerResolver := markerResolver
    }

    Detect(text) {
        if Trim(text, ' `t`r`n') == '' {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'empty-text')
        }
        if !(this.scriptResolver is Func) {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'script-resolver-unavailable')
        }

        try {
            textScripts := this.scriptResolver.Call('text', text)
            nativeScripts := this.scriptResolver.Call('locale', this.nativeLanguage)
            oppositeScripts := this.scriptResolver.Call('locale', this.oppositeLanguage)
        } catch {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'script-resolver-error')
        }
        scriptResult := this.ResolveScripts(textScripts, nativeScripts, oppositeScripts)
        if scriptResult.reason != 'shared-script' || !(this.markerResolver is Func) {
            return this._CheckAlphabet(scriptResult, text)
        }

        try markerSide := this.markerResolver.Call(text, this.nativeLanguage, this.oppositeLanguage)
        catch {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none',
                                      'marker-resolver-error', textScripts)
        }

        switch markerSide {
            case PairLanguageDetector.SIDE_NATIVE:
                return this._CheckAlphabet(this._CreateResult(PairLanguageDetector.SIDE_NATIVE, 'medium',
                                           'native-strong-marker', textScripts), text)
            case PairLanguageDetector.SIDE_OPPOSITE:
                return this._CheckAlphabet(this._CreateResult(PairLanguageDetector.SIDE_OPPOSITE, 'medium',
                                           'opposite-strong-marker', textScripts), text)
            case 'conflict':
                return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none',
                                          'conflicting-strong-markers', textScripts)
            default:
                return scriptResult
        }
    }

    _CheckAlphabet(result, sourceText) {
        if result.side == PairLanguageDetector.SIDE_UNKNOWN
            return result
        candidateLanguage := result.side == PairLanguageDetector.SIDE_NATIVE
            ? this.nativeLanguage : this.oppositeLanguage
        if !StrongLanguageMarkers.IsAlphabetCompatible(sourceText, candidateLanguage) {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none',
                                      'alphabet-mismatch', result.textScripts)
        }
        return result
    }

    ResolveScripts(textScripts, nativeScripts, oppositeScripts) {
        textScriptSet := PairLanguageDetector._ParseScripts(textScripts)
        if textScriptSet.Count == 0 {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'no-text-script', textScripts)
        }

        nativeScriptSet := PairLanguageDetector._ParseScripts(nativeScripts)
        oppositeScriptSet := PairLanguageDetector._ParseScripts(oppositeScripts)
        if nativeScriptSet.Count == 0 || oppositeScriptSet.Count == 0 {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'locale-script-unavailable', textScripts)
        }

        matchesNative := PairLanguageDetector._SetsIntersect(textScriptSet, nativeScriptSet)
        matchesOpposite := PairLanguageDetector._SetsIntersect(textScriptSet, oppositeScriptSet)
        if matchesNative && !matchesOpposite {
            return this._CreateResult(PairLanguageDetector.SIDE_NATIVE, 'high', 'native-script-only', textScripts)
        }
        if matchesOpposite && !matchesNative {
            return this._CreateResult(PairLanguageDetector.SIDE_OPPOSITE, 'high', 'opposite-script-only', textScripts)
        }
        if matchesNative && matchesOpposite {
            return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'shared-script', textScripts)
        }
        return this._CreateResult(PairLanguageDetector.SIDE_UNKNOWN, 'none', 'unsupported-script', textScripts)
    }

    _CreateResult(side, confidence, reason, textScripts := '') {
        targetLanguage := side == PairLanguageDetector.SIDE_NATIVE
            ? this.oppositeLanguage
            : side == PairLanguageDetector.SIDE_OPPOSITE
                ? this.nativeLanguage
                : ''
        return {
            side: side,
            targetLanguage: targetLanguage,
            confidence: confidence,
            reason: reason,
            textScripts: textScripts
        }
    }

    static _ParseScripts(scriptList) {
        scriptSet := Map()
        for scriptName in StrSplit(scriptList, ';') {
            scriptName := StrUpper(Trim(scriptName))
            if scriptName ~= '^[A-Z]{4}$' {
                scriptSet[scriptName] := true
            }
        }
        return scriptSet
    }

    static _SetsIntersect(firstSet, secondSet) {
        for scriptName in firstSet {
            if secondSet.Has(scriptName) {
                return true
            }
        }
        return false
    }
}

ResolveWindowsScripts(subjectKind, value) {
    return WindowsScriptResolver.Resolve(subjectKind, value)
}

ResolveStrongLanguageMarkers(sourceText, nativeLanguage, oppositeLanguage) {
    return StrongLanguageMarkers.Resolve(sourceText, nativeLanguage, oppositeLanguage)
}

#HotIf GoogleTranslator.ready
~^c:: GoogleTranslator.OnCopyPress()   ; Ctrl + C + C
#HotIf
; Keyboard auto-repeat of a held Ctrl+C produces presses without releases, so
; a double press is only counted when C was released in between.
~*c up:: GoogleTranslator.RegisterCopyRelease()


class GoogleTranslator
{
    ; Set at startup from saved settings or Windows language preferences;
    ; left empty when neither gives a clear answer (language setup is shown then).
    static nativeLanguage   := ''
    static oppositeLanguage := ''

    static ready := false
    static copyPressTick := 0
    static copyKeyReleased := true

    ; Returns true when this press completes a Ctrl+C+C double press.
    static RegisterCopyPress(pressTick := A_TickCount) {
        isDoublePress := this.copyKeyReleased && this.copyPressTick
            && pressTick - this.copyPressTick < 400
        this.copyKeyReleased := false
        ; A completed double press starts a new sequence: a third press must
        ; not translate the text again.
        this.copyPressTick := isDoublePress ? 0 : pressTick
        return isDoublePress
    }

    static RegisterCopyRelease() {
        this.copyKeyReleased := true
    }

    static OnCopyPress() {
        if this.RegisterCopyPress() {
            this.Translate(A_Clipboard)
        }
    }

    static __New() {
        this.isPrimaryScript := A_IsCompiled || A_ScriptFullPath = A_LineFile
        ; --language-setup opens the selector even when a valid pair is saved.
        this.forceLanguageSetup := this.isPrimaryScript
            && this.HasCommandLineSwitch('--language-setup')
        ; Settings, the language list and the cache live next to the script.
        if this.isPrimaryScript && !this.IsFolderWritable(A_ScriptDir) {
            MsgBox('The script folder is not writable:`n' . A_ScriptDir
                 . '`n`nMove the script to a folder you can write to, '
                 . 'for example to Documents.', 'Google Translate', 16)
            ExitApp()
        }
        this.ReadSettings()
        this.PrepareLanguageSettings()
        this.WaitForReady()
        this.wr := WebRequest()

        forceLanguageRefresh := this.isPrimaryScript
            && this.languageListLocale != this.nativeLanguage
        if !this.GetLanguageList(forceLanguageRefresh) {
            throw Error('The language list is unavailable')
        }

        provisionalNativeLanguage := this.nativeLanguage
        if !this.FinalizeLanguageSettings() {
            ExitApp()
        }
        if this.isPrimaryScript && provisionalNativeLanguage != this.nativeLanguage {
            this.GetLanguageList(true)
        }

        this.languageDetector := PairLanguageDetector(this.nativeLanguage, this.oppositeLanguage)
        forceInterfaceRefresh := this.isPrimaryScript
            && this.interfaceLocale != this.nativeLanguage
        this.GetInterfaceTexts(forceInterfaceRefresh)
        (this.darkTheme && this.FakeGui()) ; to redraw tray menu
        this.cache := this.OpenCache(A_ScriptDir . '\translate.cache',
                                     this.cacheSizeMB ? Number(this.cacheSizeMB) * 1024 * 1024 : '')
        if this.isPrimaryScript && this.cache is DisabledTranslationCache {
            MsgBox('The translation cache could not be opened and is disabled '
                 . 'until the program restarts.`n`n' . this.cache.reason,
                   'Google Translate', 48)
        }
        this.oxfordAudioUrls := Map()
        this.CreateTrayMenu()
        this.ready := true
    }

    static IsFolderWritable(folderPath) {
        probePath := folderPath . '\~write-test-' . ProcessExist() . '.tmp'
        try {
            FileOpen(probePath, 'w').Close()
            FileDelete(probePath)
            return true
        } catch {
            try FileDelete(probePath)
            return false
        }
    }

    ; The cache only holds data that can be fetched again. If its file cannot
    ; be opened, translation keeps working without it.
    static OpenCache(cachePath, maxSize := '') {
        try {
            return TranslationCache().Open(cachePath, maxSize)
        } catch Error as cacheError {
            return DisabledTranslationCache(cacheError.Message)
        }
    }

    static Translate(text, tl := '', sl := 'auto', wnd := '', mayRetryDirection := true) {
        if !this.ready {
            TrayTip('Language data has not been loaded yet, please wait...', 'Info', 'Iconi')
            SetTimer () => TrayTip(), -1500
            return
        }
        text := Trim(text, '`n`r`t ')
        if text == '' {
            return
        }
        ; The window may have been closed while a retry was pending.
        if wnd && !TranslateWindow.IsAlive(wnd) {
            return
        }
        if this.noGui && !wnd && mayRetryDirection {
            ; Windowless mode pastes the result where the text came from. A
            ; direction retry (mayRetryDirection=false) keeps that target.
            this.pasteTarget := this.GetFocusTarget()
        }
        languageSelection := this.ResolveTranslationLanguages(text, tl, sl)
        sl := languageSelection.sourceLanguage
        tl := languageSelection.targetLanguage
        directionSide := languageSelection.directionSide
        
        ; Check the cache
        cached := ''
        foundSl := sl
        if sl == 'auto' {
            for cachedSourceLanguage in this.GetAutoCacheSourceCandidates(tl, directionSide, text) {
                cached := this.cache.GetTranslation(text, cachedSourceLanguage, tl)
                if cached != '' {
                    foundSl := cachedSourceLanguage
                    break
                }
            }
        } else {
            cached := this.cache.GetTranslation(text, sl, tl)
        }
        if cached != '' {
            this.ShowTranslation(text, cached.trans, foundSl, tl, cached.variants, wnd)
            return
        }
        
        (!this.noGui && !wnd && wnd := this.ShowTranslation(text, '', sl, tl))
        chunks := this.SplitForTranslatePage(text)
        switch this.ChooseTranslator(chunks) {
            case 'TranslateDict':
                try res := this.TranslateDict(chunks[1], tl)
                catch Error as e {
                    this.WebRequestErrorHandler(wnd, e.message)
                    return
                }
                if !(res is Map) || (sl !== 'auto' && res.Has('sl') && res['sl'] !== sl) {
                    try newRes := this.TranslatePage(chunks[1], tl, sl)
                    catch Error as e {
                        this.WebRequestErrorHandler(wnd, e.message)
                        return
                    }
                    (newRes != '' && res := newRes)
                }
                translation := res['trans']
            case 'TranslatePage':
                translation := ''
                for chunk in chunks {
                    try res := this.TranslatePage(chunk, tl, sl)
                    catch Error as e {
                        this.WebRequestErrorHandler(wnd, e.message)
                        return
                    }
                    translation .= res['trans']
                }
        }
        sl := this.CorrectDetectedSourceLanguage(res['sl'], directionSide, text)
        if res.Has('oxfordAudio') && sl == res['sl'] && !this.cache.HasAudio(text, sl) {
            url := res['oxfordAudio']
            (!(url ~= 'i)^https?:') && url := 'https:' . url)
            this.oxfordAudioUrls[text . '|' . sl] := url
        }
        retryTargetLanguage := this.GetDirectionRetryTarget(sl, tl, mayRetryDirection)
        if retryTargetLanguage != '' {
            retrySourceLanguage := languageSelection.sourceLanguage == 'auto' ? 'auto' : sl
            SetTimer () => this.Translate(text, retryTargetLanguage, retrySourceLanguage, wnd, false), -100
            return
        }
        this.ShowTranslation(text, translation, sl, tl, res.Has('variants') ? res['variants'] : '', wnd)
    }

    static ResolveTranslationLanguages(text, tl := '', sl := 'auto') {
        directionSide := PairLanguageDetector.SIDE_UNKNOWN
        if tl == '' {
            if sl == 'auto' {
                directionResult := this.languageDetector.Detect(text)
                directionSide := directionResult.side
                tl := directionResult.targetLanguage != ''
                    ? directionResult.targetLanguage
                    : this.nativeLanguage
            } else {
                tl := sl == this.oppositeLanguage ? this.nativeLanguage : this.oppositeLanguage
            }
        }
        return {
            sourceLanguage: sl,
            targetLanguage: tl,
            directionSide: directionSide
        }
    }

    static GetAutoCacheSourceCandidates(targetLanguage, directionSide, sourceText) {
        if directionSide == PairLanguageDetector.SIDE_NATIVE {
            preferredLanguage := this.nativeLanguage
        } else if directionSide == PairLanguageDetector.SIDE_OPPOSITE {
            preferredLanguage := this.oppositeLanguage
        } else if targetLanguage == this.nativeLanguage {
            preferredLanguage := this.oppositeLanguage
        } else if targetLanguage == this.oppositeLanguage {
            preferredLanguage := this.nativeLanguage
        } else {
            preferredLanguage := this.oppositeLanguage
        }
        secondaryLanguage := preferredLanguage == this.nativeLanguage
            ? this.oppositeLanguage
            : this.nativeLanguage

        sourceLanguages := []
        for possibleLanguage in [preferredLanguage, secondaryLanguage] {
            if possibleLanguage != '' && possibleLanguage != targetLanguage
                    && StrongLanguageMarkers.IsAlphabetCompatible(sourceText, possibleLanguage)
                    && !this._ArrayContains(sourceLanguages, possibleLanguage) {
                sourceLanguages.Push(possibleLanguage)
            }
        }
        return sourceLanguages
    }

    static GetDirectionRetryTarget(detectedSourceLanguage, targetLanguage, mayRetryDirection := true) {
        if !mayRetryDirection || detectedSourceLanguage != targetLanguage {
            return ''
        }
        switch detectedSourceLanguage {
            case this.nativeLanguage:
                return this.oppositeLanguage
            case this.oppositeLanguage:
                return this.nativeLanguage
            default:
                return targetLanguage == this.nativeLanguage ? this.oppositeLanguage : this.nativeLanguage
        }
    }

    static CorrectDetectedSourceLanguage(detectedLanguage, directionSide, sourceText) {
        return DetectedLanguageCorrection.Resolve(detectedLanguage,
                                                  this.nativeLanguage,
                                                  this.oppositeLanguage,
                                                  directionSide, sourceText)
    }

    static _ArrayContains(items, soughtItem) {
        for item in items {
            if item == soughtItem {
                return true
            }
        }
        return false
    }

    static WebRequestErrorHandler(wnd, errorMsg) {
        if wnd && TranslateWindow.IsAlive(wnd) {
            TranslateWindow.TranslationFailed(wnd)
        }
        for hwnd, gui in TranslateWindow.guis {
            gui.Opt('+OwnDialogs')
        }
        MsgBox 'Error: ' . errorMsg, 'WebRequest Error', 16
    }

    static ReadSettings() {
        this.iniPath := A_ScriptDir . '\settings.ini'
        this.settings := [
            { key: 'darkTheme', iniKey: 'Dark Theme'                        , trayMenuItem: 'Dark Theme'            },
            { key: 'multiGUI' , iniKey: 'Multiple GUIs'                     , trayMenuItem: 'Use Multiple GUIs'     },
            { key: 'noGUI'    , iniKey: 'Windowless Mode'                   , trayMenuItem: 'Windowless Mode'       },
            { key: 'copyTrans', iniKey: 'Copy Main Translation to Clipboard', trayMenuItem: 'Copy Main Translation' }
        ]
        for i, item in this.settings {
            this.%item.key% := IniRead(this.iniPath, 'Settings', item.iniKey, i == 1)
        }
        this.slTranslatedText := IniRead(this.iniPath, 'Translated', 'Source Language', '')
        this.tlTranslatedText := IniRead(this.iniPath, 'Translated', 'Target Language', '')
        this.audioErrorTranslatedText := IniRead(this.iniPath, 'Translated', 'Audio Error', '')
        this.fontSizeTranslatedText := IniRead(this.iniPath, 'Translated', 'Font Size', '')
        this.cacheSizeMB := RegExReplace(IniRead(this.iniPath, 'Settings', 'Cache Size MB', ''), '\d*\K.*')
        if this.cacheSizeMB == '' && this.isPrimaryScript {
            IniWrite(100, this.iniPath, 'Settings', 'Cache Size MB')
        }
    }

    static PrepareLanguageSettings() {
        this.storedNativeLanguage := IniRead(this.iniPath, 'Languages', 'Native Language', '')
        this.storedOppositeLanguage := IniRead(this.iniPath, 'Languages', 'Opposite Language', '')
        this.languageListLocale := IniRead(this.iniPath, 'Languages', 'Language List Locale', '')
        this.interfaceLocale := IniRead(this.iniPath, 'Languages', 'Interface Locale', '')
        languagePreferences := WindowsLanguagePreferences.GetPreferences()
        this.preferredLanguageTags := languagePreferences.preferredTags
        this.fallbackLanguageTags := languagePreferences.fallbackTags

        nativeCandidate := StrReplace(Trim(this.storedNativeLanguage), '_', '-')
        for languageTags in [this.preferredLanguageTags, this.fallbackLanguageTags] {
            if nativeCandidate == '' && languageTags.Length
                nativeCandidate := LanguagePairAdvisor.NormalizeGoogleCode(languageTags[1])
        }
        if nativeCandidate == '' {
            ; English is only the bootstrap UI/request language here. It is not
            ; treated as a detected user language or saved automatically.
            nativeCandidate := 'en'
        }

        oppositeCandidate := StrReplace(Trim(this.storedOppositeLanguage), '_', '-')
        this.nativeLanguage := nativeCandidate
        this.oppositeLanguage := oppositeCandidate
    }

    static HasCommandLineSwitch(soughtSwitch, argumentList := unset) {
        if !IsSet(argumentList) {
            argumentList := A_Args
        }
        for commandLineArgument in argumentList {
            if commandLineArgument = soughtSwitch {
                return true
            }
        }
        return false
    }

    static ShouldShowLanguageSetup(savedPairIsValid, hasSavedLanguageValue,
                                   canAutoSave, forceLanguageSetup := false) {
        return forceLanguageSetup
            || (!savedPairIsValid && (hasSavedLanguageValue || !canAutoSave))
    }

    static FinalizeLanguageSettings() {
        supportedLanguages := this.langList['tl']
        savedNativeLanguage := LanguagePairAdvisor.FindSupportedCode(
            this.storedNativeLanguage, supportedLanguages)
        savedOppositeLanguage := LanguagePairAdvisor.FindSupportedCode(
            this.storedOppositeLanguage, supportedLanguages)
        savedPairIsValid := LanguagePairAdvisor.IsValidPair(savedNativeLanguage,
                                                             savedOppositeLanguage)
        if savedPairIsValid {
            this.nativeLanguage := savedNativeLanguage
            this.oppositeLanguage := savedOppositeLanguage
            if this.isPrimaryScript && (savedNativeLanguage != this.storedNativeLanguage
                    || savedOppositeLanguage != this.storedOppositeLanguage) {
                this.SaveLanguagePair(savedNativeLanguage, savedOppositeLanguage)
            }
            shouldShowSetup := this.isPrimaryScript
                && this.ShouldShowLanguageSetup(true, true, true,
                                                this.forceLanguageSetup)
            if shouldShowSetup {
                selectedPair := this.ShowLanguageSetup(savedNativeLanguage,
                                                       savedOppositeLanguage)
                if IsObject(selectedPair) {
                    this.SaveLanguagePair(selectedPair.nativeLanguage,
                                          selectedPair.oppositeLanguage)
                }
            }
            return true
        }

        suggestion := LanguagePairAdvisor.Suggest(this.preferredLanguageTags,
                                                   supportedLanguages,
                                                   this.fallbackLanguageTags,
                                                   savedNativeLanguage,
                                                   savedOppositeLanguage)

        if !this.isPrimaryScript {
            completedPair := LanguagePairAdvisor.CompletePairForNonInteractive(
                suggestion.nativeLanguage, suggestion.oppositeLanguage,
                supportedLanguages)
            this.nativeLanguage := completedPair.nativeLanguage
            this.oppositeLanguage := completedPair.oppositeLanguage
            return LanguagePairAdvisor.IsValidPair(this.nativeLanguage,
                                                    this.oppositeLanguage)
        }

        hasSavedLanguageValue := this.storedNativeLanguage != ''
            || this.storedOppositeLanguage != ''
        shouldShowSetup := this.ShouldShowLanguageSetup(false,
                                                        hasSavedLanguageValue,
                                                        suggestion.canAutoSave,
                                                        this.forceLanguageSetup)
        if !shouldShowSetup {
            this.SaveLanguagePair(suggestion.nativeLanguage, suggestion.oppositeLanguage)
            return true
        }

        selectedPair := this.ShowLanguageSetup(suggestion.nativeLanguage,
                                               suggestion.oppositeLanguage)
        if !IsObject(selectedPair) {
            return false
        }
        this.SaveLanguagePair(selectedPair.nativeLanguage, selectedPair.oppositeLanguage)
        return true
    }

    static SaveLanguagePair(nativeLanguage, oppositeLanguage) {
        this.nativeLanguage := nativeLanguage
        this.oppositeLanguage := oppositeLanguage
        IniWrite(nativeLanguage, this.iniPath, 'Languages', 'Native Language')
        IniWrite(oppositeLanguage, this.iniPath, 'Languages', 'Opposite Language')
    }

    static GetLanguageSetupTextFields() {
        return [
            { propertyName: 'windowTitle'   , iniKey: 'Window Title'      , sourceText: 'Language setup' },
            { propertyName: 'instruction'   , iniKey: 'Instruction'       , sourceText: 'Choose your native and second language.' },
            { propertyName: 'nativeLabel'   , iniKey: 'Native Label'      , sourceText: 'Native language' },
            { propertyName: 'oppositeLabel' , iniKey: 'Opposite Label'    , sourceText: 'Second language' },
            { propertyName: 'selectLanguage', iniKey: 'Select Language'   , sourceText: 'Select language...' },
            { propertyName: 'saveButton'    , iniKey: 'Save Button'       , sourceText: 'Save' },
            { propertyName: 'cancelButton'  , iniKey: 'Cancel Button'     , sourceText: 'Cancel' },
            { propertyName: 'chooseBoth'    , iniKey: 'Choose Both'       , sourceText: 'Please choose both languages.' },
            { propertyName: 'chooseDifferent', iniKey: 'Choose Different', sourceText: 'Please choose two different languages.' }
        ]
    }

    static GetLanguageSetupTexts(interfaceLanguage) {
        textFields := this.GetLanguageSetupTextFields()
        englishTexts := {}
        for textField in textFields {
            englishTexts.%textField.propertyName% := textField.sourceText
        }

        if interfaceLanguage == ''
                || StrLower(RegExReplace(interfaceLanguage, '-.*$')) == 'en' {
            return englishTexts
        }

        sectionName := 'Language Setup'
        cachedLocale := IniRead(this.iniPath, sectionName, 'Locale', '')
        cachedTexts := {}
        cacheIsComplete := cachedLocale = interfaceLanguage
        for textField in textFields {
            cachedText := IniRead(this.iniPath, sectionName, textField.iniKey, '')
            cachedTexts.%textField.propertyName% := cachedText
            if cachedText == '' {
                cacheIsComplete := false
            }
        }
        if cacheIsComplete {
            return cachedTexts
        }

        sourceBlock := ''
        for textField in textFields {
            sourceBlock .= textField.sourceText . '`n'
        }
        try {
            translatedText := this.TranslatePage(RTrim(sourceBlock, '`n'),
                                                 interfaceLanguage, 'en')['trans']
            translatedLines := StrSplit(Trim(translatedText, '`t`n`r '), '`n', '`r')
            if translatedLines.Length != textFields.Length {
                throw Error('Incomplete language setup translation')
            }

            localizedTexts := {}
            for textIndex, textField in textFields {
                localizedText := Trim(translatedLines[textIndex])
                if localizedText == '' {
                    throw Error('Empty language setup translation')
                }
                localizedTexts.%textField.propertyName% := localizedText
            }
        } catch {
            return englishTexts
        }

        if this.isPrimaryScript {
            for textField in textFields {
                IniWrite(localizedTexts.%textField.propertyName%, this.iniPath,
                         sectionName, textField.iniKey)
            }
            IniWrite(interfaceLanguage, this.iniPath, sectionName, 'Locale')
        }
        return localizedTexts
    }

    static ShowLanguageSetup(nativeLanguage, oppositeLanguage) {
        setupTexts := this.GetLanguageSetupTexts(nativeLanguage)
        setupLayout := this.GetLanguageSetupLayout()
        languageCodes := ['']
        languageNames := [setupTexts.selectLanguage]
        for languageCode, languageName in this.langList['tl'] {
            if languageCode == 'auto' {
                continue
            }
            languageCodes.Push(languageCode)
            languageNames.Push(languageName . ' [' . languageCode . ']')
        }

        setupState := { saved: false }
        setupWnd := Gui('+AlwaysOnTop', 'Google Translate — ' . setupTexts.windowTitle)
        setupWnd.SetFont('s10', 'Segoe UI')
        setupWnd.MarginX := setupWnd.MarginY := 18
        setupWnd.AddText('w' . setupLayout.contentWidth, setupTexts.instruction)
        setupWnd.AddText('xm y+16', setupTexts.nativeLabel)
        nativeSelector := setupWnd.AddDropDownList('xm w' . setupLayout.contentWidth,
                                                   languageNames)
        setupWnd.AddText('xm y+12', setupTexts.oppositeLabel)
        oppositeSelector := setupWnd.AddDropDownList('xm w' . setupLayout.contentWidth,
                                                     languageNames)
        nativeSelector.Choose(this.FindLanguageIndex(languageCodes, nativeLanguage))
        oppositeSelector.Choose(this.FindLanguageIndex(languageCodes, oppositeLanguage))

        saveButton := setupWnd.AddButton('xm y+20 w' . setupLayout.buttonWidth . ' Default',
                                         setupTexts.saveButton)
        cancelButton := setupWnd.AddButton('x+' . setupLayout.controlGap
                                           . ' w' . setupLayout.buttonWidth,
                                           setupTexts.cancelButton)
        saveButton.OnEvent('Click', (*) => this.ConfirmLanguagePair(
            setupWnd, nativeSelector, oppositeSelector, languageCodes, setupState,
            setupTexts))
        cancelButton.OnEvent('Click', (*) => setupWnd.Destroy())
        setupWnd.OnEvent('Close', (*) => setupWnd.Destroy())
        setupWnd.OnEvent('Escape', (*) => setupWnd.Destroy())
        this.ApplyLanguageSetupTheme(setupWnd)

        setupHwnd := setupWnd.Hwnd
        this.HideInfoGuiForLanguageSetup()
        setupWnd.Show()
        WinWaitClose('ahk_id ' . setupHwnd)
        return setupState.saved ? {
            nativeLanguage: setupState.nativeLanguage,
            oppositeLanguage: setupState.oppositeLanguage
        } : ''
    }

    static GetLanguageSetupLayout() {
        static buttonWidth := 134
        static controlGap := 10
        return {
            buttonWidth: buttonWidth,
            controlGap: controlGap,
            contentWidth: buttonWidth * 2 + controlGap
        }
    }

    static ApplyLanguageSetupTheme(setupWnd) {
        DarkTheme.SetWindowTheme(setupWnd, this.darkTheme)
    }

    static HideInfoGuiForLanguageSetup() {
        if !this.HasOwnProp('infoGui') {
            return false
        }
        try {
            this.infoGui.Hide()
            return true
        } catch {
            return false
        }
    }

    static ConfirmLanguagePair(setupWnd, nativeSelector, oppositeSelector,
                               languageCodes, setupState, setupTexts) {
        if !nativeSelector.Value || !oppositeSelector.Value {
            return
        }
        nativeLanguage := languageCodes[nativeSelector.Value]
        oppositeLanguage := languageCodes[oppositeSelector.Value]
        if nativeLanguage == '' || oppositeLanguage == '' {
            setupWnd.Opt('+OwnDialogs')
            MsgBox(setupTexts.chooseBoth, 'Google Translate', 48)
            return
        }
        if !LanguagePairAdvisor.IsValidPair(nativeLanguage, oppositeLanguage) {
            setupWnd.Opt('+OwnDialogs')
            MsgBox(setupTexts.chooseDifferent, 'Google Translate', 48)
            return
        }
        setupState.nativeLanguage := nativeLanguage
        setupState.oppositeLanguage := oppositeLanguage
        setupState.saved := true
        setupWnd.Destroy()
    }

    static FindLanguageIndex(languageCodes, languageCode) {
        for languageIndex, availableCode in languageCodes {
            if availableCode = languageCode {
                return languageIndex
            }
        }
        return 1
    }

    static ChangeLanguagePair(*) {
        selectedPair := this.ShowLanguageSetup(this.nativeLanguage, this.oppositeLanguage)
        if IsObject(selectedPair) {
            this.SaveLanguagePair(selectedPair.nativeLanguage, selectedPair.oppositeLanguage)
            Reload()
        }
    }

    static CreateTrayMenu() {
        A_TrayMenu.Delete()
        A_TrayMenu.Add('Open GUI', (*) => this.multiGUI ?
            TranslateWindow.AddGui() : (
                WinExist('Google Translate ahk_class AutoHotkeyGUI ahk_pid ' . ProcessExist()) ?
                    WinActivate() : TranslateWindow.AddGui()
                )
            )
        A_TrayMenu.Default := 'Open GUI'
        A_TrayMenu.SetIcon('Open GUI', AppIconSource.File, 1)

        A_TrayMenu.Add()
        A_TrayMenu.Add('Languages...', ObjBindMethod(this, 'ChangeLanguagePair'))
        A_TrayMenu.Add()
        
        for s in this.settings {
            A_TrayMenu.Add(s.trayMenuItem, ((s, i, p, m) => (
                (this.%s.key% ^= 1) ? m.Check(i) : m.UnCheck(i),
                (i == 'Dark Theme' && TranslateWindow.RedrawGuis(this.darkTheme) && this.FakeGui()),
                IniWrite(this.%s.key%, this.iniPath, 'Settings', s.iniKey)
            )).Bind(s))
            (this.%s.key% && A_TrayMenu.Check(s.trayMenuItem))
        }
        A_TrayMenu.Add()

        A_TrayMenu.Add('Add To Startup', AddToStartup)
        lnkPath := A_Startup . '\' . A_ScriptName . '.lnk'
        if FileExist(lnkPath) {
            A_TrayMenu.Check('Add To Startup')
        }

        A_TrayMenu.Add()

        A_TrayMenu.Add('Clear Cache', ClearCache)

        A_TrayMenu.Add()

        A_TrayMenu.Add('Open Script Folder', (*) => Run(A_ScriptDir))

        if !A_IsCompiled {
            A_TrayMenu.Add('Edit This Script', (*) => Edit())
        }
        A_TrayMenu.Add('Reload', (*) => Reload())
        A_TrayMenu.Add('Exit'  , (*) => ExitApp())

        ClearCache(*) {
            this.cache.Clear()
        }

        AddToStartup(i, p, m) {
            if FileExist(lnkPath) {
                try FileDelete(lnkPath)
                catch Error as e {
                    MsgBox 'Failed to remove shortcut from startup folder. Error: ' . e.Message, 'Error', 16
                    return
                }
                m.UnCheck(i)
            } else {
                try FileCreateShortcut(A_ScriptFullPath, lnkPath, A_ScriptDir)
                catch Error as e {
                    MsgBox 'Failed to create shortcut in startup folder', 'Error', 16
                    return
                }
                m.Check(i)
            }
        }
    }

    static FakeGui() {
        m := Map(), m.hwnd := A_ScriptHwnd
        DarkTheme.SetWindowTheme(m, this.darkTheme)
        return true
    }

    static ShowTranslation(text, trans, sl, tl, variants := '', wnd := '') {
        if trans !== '' && !this.cache.HasTranslation(text, sl, tl) {
            this.cache.SetTranslation(text, sl, tl, trans, variants)
        }
        if this.noGui && !wnd {
            A_Clipboard := trans
            if this.PasteTargetChanged() {
                ; Focus moved while the request was running: a paste now would
                ; land somewhere else, so the text stays in the clipboard.
                TrayTip('The active window changed, the translation was copied to the clipboard.',
                        'Google Translate', 'Iconi')
                SetTimer () => TrayTip(), -3000
                return
            }
            Send '^v'
            return
        }
        if wnd && !TranslateWindow.IsAlive(wnd) {
            return   ; the window was closed while the request was running
        }
        if this.copyTrans {
            A_Clipboard := trans
        }
        (variants && trans .= '`r`n`r`n' . variants)
        return TranslateWindow.ShowTranslation(sl, tl, text, trans, wnd ? wnd : this.multiGUI)
    }

    ; The window and the control that have the keyboard focus.
    static GetFocusTarget() {
        windowHwnd := WinExist('A')
        focusHwnd := 0
        if windowHwnd {
            try focusHwnd := ControlGetFocus(windowHwnd)
        }
        return {window: windowHwnd, focus: focusHwnd}
    }

    static PasteTargetChanged() {
        if !this.HasOwnProp('pasteTarget') {
            return false
        }
        current := this.GetFocusTarget()
        return current.window != this.pasteTarget.window || current.focus != this.pasteTarget.focus
    }

    static ChooseTranslator(chunks) {
        if chunks.Length > 1 {
            return 'TranslatePage'
        }
        text := chunks[1]
        encodedForUrl := UrlCodec.Encode(text)
        return StrLen(encodedForUrl) > 5000
            || (text ~= '\s' && !(text ~= '[\x{4e00}-\x{9fff}]'))
                ? 'TranslatePage'
                : 'TranslateDict'
    }

    static SmartSplit(text, maxLen) {
        ; Break points in order of preference. Members of a group are equal,
        ; so CJK text breaks at its own punctuation as well.
        static stops := [['`r`n'], ['`n'], ['.', '。', '．'], ['!', '！'], ['?', '？'],
                         [';', '；'], [',', '，', '、'], [':', '：'], [')', '）'], [' ', '　']]
        chunks := []
        i := 1
        total := StrLen(text)

        while (i <= total) {
            right := Min(i + maxLen - 1, total)

            if (right = total) {
                chunks.Push(SubStr(text, i))
                break
            }

            slice := SubStr(text, i, right - i + 1)
            best := 0

            for group in stops {
                for stop in group {
                    pos := InStr(slice, stop, false, -1)  ; r‑find
                    if (pos)
                        best := Max(best, i + pos + StrLen(stop) - 2)
                }
                if (best)
                    break
            }

            if (!best || best < i)
                best := right
            ; Never cut a surrogate pair in two: encodeURIComponent throws on
            ; a lone half.
            if (best = right && best > i && this.IsHighSurrogateAt(text, best))
                best -= 1

            chunks.Push(SubStr(text, i, best - i + 1))
            i := best + 1
        }
        return chunks
    }

    static IsHighSurrogateAt(text, pos) {
        codeUnit := NumGet(StrPtr(text), (pos - 1) * 2, 'UShort')
        return codeUnit >= 0xD800 && codeUnit <= 0xDBFF
    }

    ; translateHtml receives encoded HTML, so a chunk that is safe by its raw
    ; length can exceed the endpoint limit after characters such as & and ".
    static SplitForTranslatePage(text, maxEncodedLen := 5000) {
        chunks := []
        for chunk in this.SmartSplit(text, 4500) {
            this.AppendTranslatePageChunks(chunk, maxEncodedLen, chunks)
        }
        return chunks
    }

    static AppendTranslatePageChunks(text, maxEncodedLen, chunks) {
        if StrLen(HtmlCodec.Encode(text)) <= maxEncodedLen {
            chunks.Push(text)
            return
        }

        splitLen := Max(1, StrLen(text) // 2)
        for chunk in this.SmartSplit(text, splitLen) {
            this.AppendTranslatePageChunks(chunk, maxEncodedLen, chunks)
        }
    }

    static TranslatePage(text, tl, sl := 'auto') {
        static hdrs := Map(
                  'X-Goog-API-Key', Config.API_KEYS.translatePage,
                  'User-Agent'    , 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                                  . 'AppleWebKit/537.36 (KHTML, like Gecko) '
                                  . 'Chrome/138.0.0.0 Safari/537.36',
                  'Content-Type'  , 'application/json+protobuf'
               )

        text := HtmlCodec.Encode(text)
        if StrLen(text) > 5000 {
            throw ValueError('Encoded translation chunk exceeds 5000 characters')
        }
        Loop 2 {
            res := this.wr.Fetch(Config.URLS.translatePage, 'POST', hdrs, LightJson.Stringify([[[text], sl, tl], 'wt_lib']))
            obj := LightJson.Parse(res.text)
            if obj.Has(1)
                break
            Sleep 100
            sl := 'auto'
        }
        trans := obj[1][1]
        return Map('trans', HtmlCodec.Decode(trans), 'sl', obj.Has(2) ? obj[2][1] : sl)
    }

    static TranslateDict(text, tl := 'en') {
        static hdrs := Map(
                 'User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                             . 'AppleWebKit/537.36 (KHTML, like Gecko) '
                             . 'Chrome/138.0.0.0 Safari/537.36',
                 'x-referer' , 'chrome-extension://mgijmajocgfcbeboacabfgobmjgjcoja'
               )

        encodedText := UrlCodec.Encode(text)
        if StrLen(encodedText) > 5000 {
            MsgBox 'Text is too long. Please shorten it to less than 5000 characters.', 'Error'
            return
        }
        url := Config.URLS.dictionary . '?language=' . tl
            . '&key=' . Config.API_KEYS.dictionary . '&strategy=2'
            . '&term=' . encodedText

        res := this.wr.Fetch(url,, hdrs)
        trans := LightJson.Parse(json := res.text)
        if !trans.Has('translateResponse') {
            return
        }
        translateResponse := trans['translateResponse']
        basic := translateResponse['translateText']
        variants := ''
        if translateResponse.Has('bilingualDictionary') {
            for item in translateResponse['bilingualDictionary'] {
                for term in item['terms'] {
                    variants .= term .= '`r`n'
                }
                variants .= '`r`n'
            }
        }
        res := Map(
            'trans', basic,
            'variants', RTrim(variants, '`r`n'),
            'sl', translateResponse['detectedSourceLanguage']
        )
        (trans.Has('oxfordAudio') && res['oxfordAudio'] := trans['oxfordAudio'])
        return res
    }

    static GetLanguageList(forceRefresh := false) {
        hdrs := Map(
                    'User-Agent'      , 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                                      . 'AppleWebKit/537.36 (KHTML, like Gecko) '
                                      . 'Chrome/138.0.0.0 Safari/537.36',
                    'accept-language' , this.nativeLanguage
                                      . (this.nativeLanguage != 'en' ? ',en' : '')
               )
        path := A_ScriptDir . '\langlist.json'
        loadedFromFile := false
        if !forceRefresh && FileExist(path) {
            langList := FileRead(path)
            loadedFromFile := true
        } else {
            try {
                res := this.wr.Fetch(Config.URLS.languages,, hdrs)
                langList := LightJson.Beautify(res.text, '    ')
            } catch as e {
                ; A refresh is best-effort: keep working with the cached list.
                if FileExist(path) {
                    langList := FileRead(path)
                    loadedFromFile := true
                } else {
                    if !this.isPrimaryScript {
                        return false
                    }
                    MsgBox 'Failed to fetch language list: ' . e.message, 'Error', 16
                    ExitApp()
                }
            } else {
                FileOpen(path, 'w', 'UTF-8').Write(langList)
                if this.isPrimaryScript {
                    this.languageListLocale := this.nativeLanguage
                    IniWrite(this.nativeLanguage, this.iniPath,
                             'Languages', 'Language List Locale')
                }
            }
        }
        try {
            this.langList := this.NormalizeLangLists(LightJson.Parse(langList))
        } catch Error as parseError {
            ; A damaged local copy is replaced by a fresh one, once.
            if loadedFromFile && !forceRefresh {
                return this.GetLanguageList(true)
            }
            ; A list loaded earlier in this session keeps the program usable.
            if !this.isPrimaryScript || this.HasOwnProp('langList') {
                return false
            }
            MsgBox 'Failed to read the language list: ' . parseError.Message, 'Error', 16
            ExitApp()
        }
        return true
    }

    ; langlist.json is written once and then reused forever, so it drifts as
    ; Google adds languages - a code it reports can be missing locally. Refetch
    ; on the first such miss and rebuild the combo box data. Once per session:
    ; Google can also report codes it does not list at all, and that must not
    ; turn into a fetch on every translation.
    static RefreshLanguages() {
        static tried := false
        if tried {
            return false
        }
        tried := true
        if !this.GetLanguageList(true) {
            return false
        }
        if TranslateWindow.HasOwnProp('slArr') {
            TranslateWindow.CreateLangArrays(this.langList)
        }
        return true
    }

    static NormalizeLangLists(langList) {
        langList['sl'] := this.InsertMissingLanguages(langList['sl'], langList['tl'], true)
        langList['tl'] := this.InsertMissingLanguages(langList['tl'], langList['sl'], false)
        this.UseLongerNames(langList)
        return langList
    }

    static InsertMissingLanguages(targetList, sourceList, excludeAuto := false) {
        newList := LinkedOrderedMap()
        newList.CaseSense := targetList.CaseSense
        
        for langCode, langName in targetList {
            newList[langCode] := langName
            relatedLangs := this.FindRelatedLanguages(langCode, langName, sourceList, targetList, excludeAuto)
            for relatedCode, relatedName in relatedLangs {
                newList[relatedCode] := relatedName
            }
        }
        return newList
    }

    static FindRelatedLanguages(currentCode, currentName, sourceList, targetList, excludeAuto) {
        related := LinkedOrderedMap()
        
        for sourceCode, sourceName in sourceList {
            if excludeAuto && sourceCode == 'auto' {
                continue
            }
            if targetList.Has(sourceCode) {
                continue
            }
            if this.AreLanguagesRelated(currentCode, currentName, sourceCode, sourceName) {
                related[sourceCode] := sourceName
            }
        }
        return related
    }

    static AreLanguagesRelated(code1, name1, code2, name2) {
        if this.GetLanguageFamily(code1) == this.GetLanguageFamily(code2) {
            return true
        }
        if this.GetBaseName(name1) == this.GetBaseName(name2) {
            return true
        }
        return false
    }

    static GetLanguageFamily(code) => RegExReplace(code, '-.*$')  ; Returns the part before the hyphen (e.g., 'zh' from 'zh-CN')

    static GetBaseName(name) => RegExReplace(name, '\s*\(.*\)$')  ; Removes parenthetical parts (e.g., 'Chinese' from 'Chinese (traditional)')

    static UseLongerNames(langList) {
        ; go through all the languages ​​and choose longer names
        for langCode, slName in langList['sl'] {
            if langCode == 'auto' {
                continue
            }
            if langList['tl'].Has(langCode) {
                tlName := langList['tl'][langCode]
                longerName := StrLen(tlName) > StrLen(slName) ? tlName : slName
                if longerName != slName {
                    langList['sl'][langCode] := longerName
                }
                if longerName != tlName {
                    langList['tl'][langCode] := longerName
                }
            }
        }
    }

    static GetInterfaceTexts(forceRefresh := false) {
        slTranslatedText := tlTranslatedText := audioErrorTranslatedText := fontSizeTranslatedText := ''
        textsAreMissing := this.slTranslatedText == '' || this.tlTranslatedText == ''
            || this.audioErrorTranslatedText == '' || this.fontSizeTranslatedText == ''
        if forceRefresh || textsAreMissing {
            try {
                res := this.TranslatePage('
                (
                    Source Language
                    Target Language
                    Playback error: unsupported language for TTS.
                    Font Size
                )', this.nativeLanguage, 'en')['trans']
                res := Trim(res, '`t`n`r ')
                arr := StrSplit(res, '`n', '`r')
                if arr.Length < 4 {
                    throw Error('Incomplete interface translation')
                }
                slTranslatedText := Trim(arr[1])
                tlTranslatedText := Trim(arr[2])
                audioErrorTranslatedText := Trim(arr[3])
                fontSizeTranslatedText := Trim(arr[4])
            } catch {
                slTranslatedText         := 'Source Language'
                tlTranslatedText         := 'Target Language'
                audioErrorTranslatedText := 'Playback error: unsupported language for TTS.'
                fontSizeTranslatedText   := 'Font Size'
            } else {
                if this.isPrimaryScript {
                    if forceRefresh || this.slTranslatedText == '' {
                        IniWrite(slTranslatedText, this.iniPath, 'Translated', 'Source Language')
                    }
                    if forceRefresh || this.tlTranslatedText == '' {
                        IniWrite(tlTranslatedText, this.iniPath, 'Translated', 'Target Language')
                    }
                    if forceRefresh || this.audioErrorTranslatedText == '' {
                        IniWrite(audioErrorTranslatedText, this.iniPath, 'Translated', 'Audio Error')
                    }
                    if forceRefresh || this.fontSizeTranslatedText == '' {
                        IniWrite(fontSizeTranslatedText, this.iniPath, 'Translated', 'Font Size')
                    }
                }
                if forceRefresh {
                    this.slTranslatedText := slTranslatedText
                    this.tlTranslatedText := tlTranslatedText
                    this.audioErrorTranslatedText := audioErrorTranslatedText
                    this.fontSizeTranslatedText := fontSizeTranslatedText
                }
                if this.isPrimaryScript {
                    this.interfaceLocale := this.nativeLanguage
                    IniWrite(this.nativeLanguage, this.iniPath,
                             'Languages', 'Interface Locale')
                }
            }
        }
        for i, name in ['slTranslatedText', 'tlTranslatedText', 'audioErrorTranslatedText', 'fontSizeTranslatedText'] {
            if this.%name% == '' {
                this.%name% := %name%
            }
        }
    }

    static WaitForReady() {
        if   this.slTranslatedText
          && this.tlTranslatedText
          && this.audioErrorTranslatedText
          && this.fontSizeTranslatedText
          && FileExist(A_ScriptDir . '\langlist.json') {
            return
        }
        this.BlockTrayMenu()
        this.CreateInfoGui()
        SetTimer ObjBindMethod(this, 'UpdateInfoGui'), 400
    }

    static CreateInfoGui() {
        static exStyles := (WS_EX_COMPOSITED := 0x2000000) | (WS_EX_LAYERED := 0x80000)
        this.infoText := 'Language data is loading, please wait'
        this.infoGui := wnd := Gui('-Caption +AlwaysOnTop +Owner +' . exStyles)
        wnd.MarginX := wnd.MarginY := 20
        wnd.BackColor := 0x202020
        wnd.infoIcon := wnd.AddPic('w32 h32 Icon1', AppIconSource.File)
        wnd.infoIcon.GetPos(, &iconY,, &iconH)
        wnd.SetFont('s16 Bold cE0E0E0', 'Calibri')
        wnd.infoHeading := wnd.AddText('x+6 yp', 'Google Translate')
        wnd.infoHeading.GetPos(, &titleY,, &titleH)
        wnd.SetFont('norm')
        headerBottom := Max(iconY + iconH, titleY + titleH)
        wnd.txt := wnd.AddText('xm y' . (headerBottom + 5), this.infoText . '...')
        wnd.Show('Hide')
        wnd.GetPos(,, &w, &h)
        rw := rh := 12
        d := A_ScreenDPI / 96
        WinSetRegion('0-0 w' . w * d . ' h' . h * d . ' r' . rw . '-' . rh, wnd)
        wnd.Show()
    }

    static UpdateInfoGui() {
        static RepeatStr(str, count) => StrReplace(Format('{:' . count . '}', ''), ' ', str)
        static counter := 0
        if !this.ready {
            this.infoGui.txt.Text := this.infoText . RepeatStr('.', Mod(counter++, 4))
        } else {
            SetTimer , 0
            this.infoGui.txt.Text := 'Ready!'
            Sleep 500
            this.infoGui.Destroy()
            this.BlockTrayMenu(false)
        }
    }

    static BlockTrayMenu(prevent := true) {
        if !this.HasOwnProp('onTrayMenuClick') {
            this.onTrayMenuClick := ObjBindMethod(this, 'AHK_NOTIFYICON')
        }
        OnMessage(0x404, this.onTrayMenuClick, prevent)
    }

    static AHK_NOTIFYICON(wp, lp, *) {
        static WM_LBUTTONDBLCLK := 0x203, WM_RBUTTONDOWN := 0x204, WM_RBUTTONUP := 0x205
        if (lp = WM_LBUTTONDBLCLK || lp = WM_RBUTTONDOWN || lp = WM_RBUTTONUP) {
            return 0  ; Prevent interaction with tray menu
        }
    }
}

class TranslateWindow
{
    static guis := LinkedOrderedMap(), lastGui := ''
         , resizeParams := {wnd: '', height: ''}
         , adjustLayoutTimer := ObjBindMethod(this, 'AdjustLayout', this.resizeParams)
         , restoreTextTimers := Map(), restoreTextExpected := Map()

    static iniPath => GoogleTranslator.iniPath

    static fontSize[i] {
        get {
            return this.HasOwnProp('_fontSize' . i)
                ? this._fontSize%i%
                : IniRead(this.iniPath, 'Settings', 'Edit Font Size ' . i, 11)
        }
        set {
            size := Max(8, Min(28, value))
            this._fontSize%i% := size
            for hwnd, wnd in this.guis {
                wnd.edit%i%.SetFont('s' . size)
            }
            if !this.HasOwnProp('saveFontSizeTimer' . i) {
                this.saveFontSizeTimer%i% := ObjBindMethod(this, 'SaveFontSize', i)
            }
            SetTimer this.saveFontSizeTimer%i%, -800
        }
    }

    static SaveFontSize(i) {
        IniWrite(this._fontSize%i%, this.iniPath, 'Settings', 'Edit Font Size ' . i)
        this.DeleteProp('saveFontSizeTimer' . i)
    }

    static ShowTranslation(sl, tl, sTxt, tTxt, newGui) {
        if !this.guis.Count || newGui == true {
            wnd := this.AddGui(sl, tl, sTxt, tTxt)
        } else {
            wnd := newGui is Gui ? newGui : this.lastGui
            wnd.lng1.Text := this.LangDisplayName('sl', sl)
            wnd.lng2.Text := this.LangDisplayName('tl', tl)
            wnd.edit1.Text := sTxt
            wnd.edit2.Text := tTxt
            wnd.play1.Enabled := true
            (tTxt != '' && wnd.play2.Enabled := true)
        }
        this.lastSl := sl
        SetTimer wnd.waitTimer, tTxt == '' ? 300 : 0
        (tTxt != '' && this.AdjustGuiSize(wnd, tTxt))
        return wnd
    }

    static TranslationFailed(wnd) {
        SetTimer wnd.waitTimer, 0
        wnd.edit2.Text := '¯\_(ツ)_/¯'
    }

    static AddGui(sl := '', tl := '', sTxt := '', tTxt := '') {
        static EVENT_SYSTEM_MOVESIZESTART := 0xA, EVENT_SYSTEM_MOVESIZEEND := 0xB
             , WM_NCLBUTTONDOWN := 0xA1, HTCAPTION := 2, WM_NCACTIVATE := 0x86

        this.lastSl := ''
        (!sl && sl := GoogleTranslator.oppositeLanguage)
        (!tl && tl := GoogleTranslator.nativeLanguage)
        if !this.HasOwnProp('slArr') {
            this.CreateLangArrays(GoogleTranslator.langList)
        }
        wnd := this.CreateGui(sl, tl, sTxt, tTxt)
        wnd.edge := 'right'
        this.StoreHorizontalCoords(wnd)
        if this.lastGui {
            if this.GetNormalWindowPosition(this.lastGui.hwnd, &x, &y) {
                wnd.Show('x' . (x + 30) . ' y' . (y + 30))
                this.KeepInWorkArea(wnd.Hwnd)
            } else {
                wnd.Show()
            }
        } else {
            x := IniRead(this.iniPath, 'Coords', 'GuiX', '')
            y := IniRead(this.iniPath, 'Coords', 'GuiY', '')
            if x == '' || y == '' {
                wnd.Show()
            } else {
                ; The saved position may be on a monitor that is gone now.
                wnd.Show('x' . x . ' y' . y)
                this.KeepInWorkArea(wnd.Hwnd)
            }
        }
        Loop 2 {
            this.SetSelToCB(wnd.lng%A_Index%)
        }
        wnd.txt1.Focus()
        this.lastGui := wnd
        this.guis[wnd.hwnd] := wnd
        SendMessage(WM_NCACTIVATE, true,,, wnd)

        this.StoreHorizontalCoords(wnd)

        if this.guis.Count == 1 {
            this.hook := WinEventHook(
                EVENT_SYSTEM_MOVESIZESTART,
                EVENT_SYSTEM_MOVESIZEEND,
                ObjBindMethod(this, 'OnStartResize')
            )
            OnMessage(0x201, this.onLButton := (*) => PostMessage(WM_NCLBUTTONDOWN, HTCAPTION))
            OnMessage(0x214, this.onSizing     := ObjBindMethod(this, 'WM_SIZING'))
            OnMessage(0x20A, this.onMouseWheel := ObjBindMethod(this, 'WM_MOUSEWHEEL'))
            OnMessage(0x100, this.onKeyDown    := ObjBindMethod(this, 'WM_KEYDOWN'))
        }
        wnd.GetClientPos(,, &guiW, &guiH)
        wnd.Opt('+MinSize' . guiW . 'x' . guiH)
        return wnd
    }

    ; GetWindowPlacement returns the restored position even while the window is
    ; minimized. Its RECT uses workspace coordinates, so translate it to the
    ; virtual-screen coordinates expected by Gui.Show and IniWrite.
    static GetNormalWindowPosition(windowHwnd, &x, &y) {
        static WINDOWPLACEMENT_SIZE := 44
             , MONITORINFO_SIZE := 40
             , MONITOR_DEFAULTTONEAREST := 2

        windowPlacement := Buffer(WINDOWPLACEMENT_SIZE, 0)
        NumPut('UInt', WINDOWPLACEMENT_SIZE, windowPlacement)
        if !DllCall('User32\GetWindowPlacement', 'Ptr', windowHwnd, 'Ptr', windowPlacement, 'Int') {
            return false
        }

        x := NumGet(windowPlacement, 28, 'Int')
        y := NumGet(windowPlacement, 32, 'Int')

        monitorHandle := DllCall('User32\MonitorFromWindow', 'Ptr', windowHwnd,
                                                           'UInt', MONITOR_DEFAULTTONEAREST, 'Ptr')
        if monitorHandle {
            monitorInfo := Buffer(MONITORINFO_SIZE, 0)
            NumPut('UInt', MONITORINFO_SIZE, monitorInfo)
            if DllCall('User32\GetMonitorInfoW', 'Ptr', monitorHandle, 'Ptr', monitorInfo, 'Int') {
                x += NumGet(monitorInfo, 20, 'Int') - NumGet(monitorInfo, 4, 'Int')
                y += NumGet(monitorInfo, 24, 'Int') - NumGet(monitorInfo, 8, 'Int')
            }
        }
        return true
    }

    ; Moves a window back into the work area of the nearest monitor when part
    ; of it is outside: after a cascade of windows, or with a saved position
    ; on a monitor that has been disconnected.
    static KeepInWorkArea(windowHwnd) {
        static MONITORINFO_SIZE := 40, MONITOR_DEFAULTTONEAREST := 2
        WinGetPos(&x, &y, &width, &height, windowHwnd)
        monitorHandle := DllCall('User32\MonitorFromWindow', 'Ptr', windowHwnd,
                                                           'UInt', MONITOR_DEFAULTTONEAREST, 'Ptr')
        monitorInfo := Buffer(MONITORINFO_SIZE, 0)
        NumPut('UInt', MONITORINFO_SIZE, monitorInfo)
        if !monitorHandle
                || !DllCall('User32\GetMonitorInfoW', 'Ptr', monitorHandle, 'Ptr', monitorInfo, 'Int') {
            return
        }
        workLeft   := NumGet(monitorInfo, 20, 'Int')
        workTop    := NumGet(monitorInfo, 24, 'Int')
        workRight  := NumGet(monitorInfo, 28, 'Int')
        workBottom := NumGet(monitorInfo, 32, 'Int')
        ; The top-left corner wins when the window is larger than the work area.
        newX := Max(workLeft, Min(x, workRight - width))
        newY := Max(workTop, Min(y, workBottom - height))
        if newX != x || newY != y {
            WinMove(newX, newY,,, windowHwnd)
        }
    }

    ; True while wnd is an open translator window.
    static IsAlive(wnd) {
        try return this.guis.Has(wnd.Hwnd)
        return false
    }

    static RemoveGui(hwnd) {
        removedWnd := this.guis.Delete(hwnd)
        AudioChannel.RemoveChannel(removedWnd.play1.hwnd)
        AudioChannel.RemoveChannel(removedWnd.play2.hwnd)
        this.CancelRestoreTextTimer(removedWnd.edit1.hwnd)
        this.CancelRestoreTextTimer(removedWnd.edit2.hwnd)
        this.lastGui := ''
        if this.guis.Count {
            for remainingHwnd, remainingWnd in this.guis {
                this.lastGui := remainingWnd
            }
        } else {
            if this.GetNormalWindowPosition(hwnd, &x, &y) {
                IniWrite x, this.iniPath, 'Coords', 'GuiX'
                IniWrite y, this.iniPath, 'Coords', 'GuiY'
            }
            OnMessage(0x201, this.onLButton   , 0)
            OnMessage(0x214, this.onSizing    , 0)
            OnMessage(0x20A, this.onMouseWheel, 0)
            OnMessage(0x100, this.onKeyDown   , 0)
            this.hook := ''
        }
        SetTimer removedWnd.waitTimer, 0
        removedWnd.Destroy()
    }

    static OnStartResize(hWinEventHook, event, hwnd, idObject, *) {
        static EVENT_SYSTEM_MOVESIZESTART := 0xA, EVENT_SYSTEM_MOVESIZEEND := 0xB
        if this.guis.Has(hwnd) {
            wnd := this.guis[hwnd]
            switch event {
                case EVENT_SYSTEM_MOVESIZESTART : this.StoreVerticalCoords(wnd)
                case EVENT_SYSTEM_MOVESIZEEND   : this.DeleteProp('changeResizeMode')
            }
        }
    }

    static WM_KEYDOWN(wp, lp, msg, hwnd) {
        static VK_ENTER := 0x000D
        if wp != VK_ENTER {
            return
        }
        ctrl := GuiCtrlFromHwnd(hwnd)
        if !ctrl {
            return
        }
        try wnd := ctrl.Gui
        catch {
            return
        }
        if !this.guis.Has(wnd.hwnd) {
            return
        }
        ; Shift+Enter inserts a line break: the edits have no WantReturn, so
        ; a plain Enter would reach the default button instead.
        if ctrl.Type == 'Edit' && GetKeyState('Shift') {
            EditPaste('`r`n', ctrl)
            return 0
        }
        ; Enter in the bottom field acts like its own reverse-translation button.
        this.TranslateFromGui(wnd, ctrl == wnd.edit2 ? 'backward' : 'forward')
        return 0
    }

    static WM_SIZING(wp, lp, msg, hwnd) {
        if this.guis.Has(hwnd) {
            this.guis[hwnd].edge := ['left', 'right', 'top', 'topLeft', 'topRight', 'bottom', 'bottomLeft', 'bottomRight'][wp]
        }
    }

    static WM_MOUSEWHEEL(wp, lp, msg, hwnd) {
        static MK_CONTROL := 0x8
        if !((wp & MK_CONTROL) && ctrl := GuiCtrlFromHwnd(hwnd)) {
            return
        }
        try wnd := ctrl.Gui
        catch {
            return
        }
        if !this.guis.Has(wnd.hwnd) {
            return
        }
        editNum := (ctrl == wnd.edit1) ? 1 : (ctrl == wnd.edit2) ? 2 : 0
        if !editNum {
            return
        }
        controlHwnd := ctrl.hwnd
        ; The text to bring back is taken when the hint first appears, or anew
        ; when something has replaced the hint in the meantime.
        if !this.restoreTextTimers.Has(controlHwnd)
                || !this.restoreTextExpected.Has(controlHwnd)
                || ctrl.Text !== this.restoreTextExpected[controlHwnd] {
            this.CancelRestoreTextTimer(controlHwnd)
            this.restoreTextTimers[controlHwnd] := ObjBindMethod(this, 'RestoreText', ctrl, ctrl.Text, controlHwnd)
        }
        turn := wp >> 16 & 0xFFFF
        this.fontSize[editNum] += turn > 0 && turn <= 0x7FFF ? 1 : -1
        hintText := GoogleTranslator.fontSizeTranslatedText . ': ' . this.fontSize[editNum] . ' pt'
        ctrl.Text := hintText
        this.restoreTextExpected[controlHwnd] := hintText
        SetTimer this.restoreTextTimers[controlHwnd], -800
    }

    ; Brings back the text replaced by the font size hint, unless something
    ; else - a new translation, the user's typing - has replaced the hint.
    static RestoreText(ctrl, originalText, controlHwnd) {
        hintText := this.restoreTextExpected.Has(controlHwnd)
            ? this.restoreTextExpected.Delete(controlHwnd)
            : ''
        try {
            if ctrl.Text == hintText {
                ctrl.Text := originalText
            }
        }
        if this.restoreTextTimers.Has(controlHwnd) {
            this.restoreTextTimers.Delete(controlHwnd)
        }
    }

    static CancelRestoreTextTimer(controlHwnd) {
        if this.restoreTextExpected.Has(controlHwnd) {
            this.restoreTextExpected.Delete(controlHwnd)
        }
        if !this.restoreTextTimers.Has(controlHwnd) {
            return
        }
        timerCallback := this.restoreTextTimers.Delete(controlHwnd)
        SetTimer timerCallback, 0
    }

    static CreateGui(sl, tl, sTxt, tTxt) {
        static ES_NOHIDESEL := 0x100, BS_ICON := 0x40
        (sl ~= '^zh(?!-)' && sl := 'zh-TW')
        (tl ~= '^zh(?!-)' && tl := 'zh-TW')
        wnd := Gui('AlwaysOnTop LastFound Resize -MaximizeBox', 'Google Translate')
        wnd.waitTimer := ObjBindMethod(this, 'WaitForTranslation', wnd)
        wnd.MarginX := wnd.MarginY := 10
        wnd.OnEvent('Close' , (*) => this.RemoveGui(wnd.hwnd))
        wnd.OnEvent('Escape', (*) => this.RemoveGui(wnd.hwnd))
        wnd.OnEvent('Size', ObjBindMethod(this, 'OnGuiSize'))

        maxTranslatedTextWidth := Max(
            this.GetTextWidth(8, 'Verdana', GoogleTranslator.slTranslatedText . ':'),
            this.GetTextWidth(8, 'Verdana', GoogleTranslator.tlTranslatedText . ':')
        )
        (txtWidth := maxTranslatedTextWidth < 100 ? 100 : maxTranslatedTextWidth)

        for i, lang in [GoogleTranslator.slTranslatedText, GoogleTranslator.tlTranslatedText] {
            wnd.SetFont('s8', 'Verdana')
            wnd.txt%i% := wnd.AddText('xm y+15 Right w' . txtWidth, lang . ':')                                                 ; <————————————— Text 'Source Language', 'Target Language'
            lang := ['sl', 'tl'][i]
            wnd.lng%i% := wnd.AddComboBox('x+5 yp-2 w182 Choose' . this.LangIndex(lang, i == 1 ? sl : tl), this.%lang%Arr)      ; <————————————— ComboBoxes with language selection
            
            wnd.swapLang%i% := wnd.AddButton('x+5 yp-1 w23 h23 ' . BS_ICON)                                                     ; <————————————— Swap language buttons
            wnd.swapLang%i%.OnEvent('Click', (*) => (
                sourceLang := wnd.lng1.Text,
                (this.LangNameToCode(sourceLang) != 'auto' && (
                    targetLang := wnd.lng2.Text,
                    wnd.lng1.Text := targetLang,
                    wnd.lng2.Text := sourceLang
                ))
            ))
            this.SetButtonIcon(wnd.swapLang%i%, 'swap')
            (i == 1 && wnd.swapLang1.GetPos(&xSwap))
            txt := i == 1 ? sTxt : tTxt
            w := xSwap + 13
            wnd.SetFont('s' . this.fontSize[i], 'Calibri')
            (i == 1 && wnd.testTxt := wnd.AddText('xm y+9 Hidden'))
            h := this.GetTextHeight(11, 'Calibri', w, txt)
            switch {
                case txt == '' || h < 60 : hOpt := ' h60'
                case i == 1 && h > 60 : hOpt := ' h60'
                case i == 2 && h > 350 : hOpt := ' h350'
                default : hOpt := ''
            }
            wnd.edit%i% := wnd.AddEdit('xm ' . (i == 1 ? 'yp' : 'y+9') . ' w' . w . hOpt . ' Multi ' . ES_NOHIDESEL, txt)       ; <————————————— Source and target text fields
            wnd.edit%i%.OnEvent('Change', ((i, *) => (
                wnd.edit%i%.Text !== ''
                    ? (wnd.play%i%.Enabled := true)
                    : (!AudioChannel.channels.Has(wnd.play%i%.hwnd) && wnd.play%i%.Enabled := false)
            )).Bind(i))
            wnd.SetFont('s8', 'Verdana')
            wnd.play%i% := wnd.AddButton('xm y+5 w52 h23 ' . BS_ICON . (txt == '' ? ' Disabled' : ''))                          ; <————————————— Play-Pause button
            this.SetButtonIcon(wnd.play%i%, 'play', 12)
            wnd.play%i%.OnEvent('Click', ObjBindMethod(this, 'PlayPause', wnd, i))

            wnd.stop%i% := wnd.AddButton('Disabled x+5 yp wp hp ' . BS_ICON)                                                    ; <————————————— Stop button
            this.SetButtonIcon(wnd.stop%i%, 'stop', 12)
            wnd.stop%i%.OnEvent('Click', ((i, *) => this.Stop(wnd, i)).Bind(i))
            wnd.trans%i% := wnd.AddButton('x' . xSwap - 46 . ' yp w70 hp ' . BS_ICON . (i == 1 ? ' Default' : ''))              ; <————————————— Translate buttons
            this.SetButtonIcon(wnd.trans%i%, i == 1 ? 'translate' : 'backward', i == 1 ? 16 : 15)
            wnd.trans%i%.OnEvent('Click', ObjBindMethod(this, 'TranslateFromGui', wnd, i == 1 ? 'forward' : 'backward'))
        }
        (GoogleTranslator.darkTheme && DarkTheme.SetWindowTheme(wnd))
        return wnd
    }

    static AdjustGuiSize(wnd, txt) {
        wnd.edit2.GetPos(,, &editW, &editH)
        wnd.GetClientPos(,, &guiW, &guiH)
        newEditH := this.GetTextHeight(this.fontSize[2], 'Calibri', editW, txt) + 15
        (newEditH < 60 && newEditH := 60)
        (newEditH > 350 && newEditH := 350)
        newHeight := guiH + newEditH - editH

        wnd.edge := 'bottom'
        this.StoreVerticalCoords(wnd)
        wnd.Show('h' . newHeight)

        this.ShedulePosCorrection(wnd, newHeight)
    }

    static WaitForTranslation(wnd) {
        edit := wnd.edit2
        text := edit.Text
        if text ~= '[^\.]' {
            SetTimer , 0
            return
        }
        switch text {
            case ''   : newText := '.'
            case '.'  : newText := '..'
            case '..' : newText := '...'
            default   : newText := ''
        }
        edit.Text := newText
    }

    static SetSelToCB(ctrl) {
        static CB_GETCOMBOBOXINFO := 0x164, EM_SETSEL := 0xB1
             , size := 40 + A_PtrSize * 3
             , COMBOBOXINFO := Buffer(size)
             , _ := NumPut('UInt', size, COMBOBOXINFO)

        SendMessage CB_GETCOMBOBOXINFO,, COMBOBOXINFO, ctrl
        hEdit := NumGet(COMBOBOXINFO, 40 + A_PtrSize, 'Ptr')
        SendMessage EM_SETSEL, -2, -1, hEdit
    }

    static RedrawGuis(theme) {
        static WM_NCACTIVATE := 0x86
        for hwnd in this.guis {
            wnd := GuiFromHwnd(hwnd)
            DarkTheme.SetWindowTheme(wnd, theme)
            WinRedraw(wnd)
            this.SetSelToCB(wnd.lng1)
            this.SetSelToCB(wnd.lng2)
            active := WinActive(wnd)
            SendMessage(WM_NCACTIVATE, !active,,, wnd)
            SendMessage(WM_NCACTIVATE,  active,,, wnd)
        }
        return !this.guis.Count
    }

    static SetButtonIcon(ctrl, icon, size := 16) {
        static IMAGE_ICON := 1, BM_SETIMAGE := 0xF7
        size := Round(size * A_ScreenDPI / 96)
        PostMessage BM_SETIMAGE, IMAGE_ICON, Icons.Get(icon, size), ctrl
    }

    static GetTextFromField(wnd, fieldNum) {
        selectedText := Trim(EditGetSelectedText(wnd.edit%fieldNum%), ' `t`r`n')
        if selectedText != '' {
            return selectedText
        }
        text := Trim(wnd.edit%fieldNum%.Text, ' `t`r`n')
        if text != '' {
            return text
        }
        return ''
    }

    static TranslateFromGui(wnd, direction := 'forward', *) {
        text := this.GetTextFromField(wnd, direction == 'forward' ? 1 : 2)
        if text == '' {
            return
        }
        if direction == 'backward' {
            wnd.edit1.Text := text
        }
        wnd.edit2.Text := ''
        SetTimer wnd.waitTimer, 300
        txt1 := wnd.lng%direction == 'forward' ? 1 : 2%.Text
        txt2 := wnd.lng%direction == 'forward' ? 2 : 1%.Text
        sl := this.LangNameToCode(txt1)
        tl := this.LangNameToCode(txt2)
        ; An empty or unknown language name lets Google detect the source.
        if sl == '' {
            sl := 'auto'
        }
        if (tl == 'auto' || tl == '') {
            tl := this.lastSl ? this.lastSl : GoogleTranslator.nativeLanguage
        }
        if direction == 'backward' {
            wnd.lng1.Text := txt1
            wnd.lng2.Text := txt2
        }
        GoogleTranslator.Translate(text, tl, sl, wnd)
    }

    static LangNameToCode(lngName) {
        ; The combo boxes are editable and may hold an empty string, which
        ; InStr does not accept as a needle.
        lngName := Trim(lngName)
        if lngName == '' {
            return ''
        }
        for ln in ['sl', 'tl'] {
            for lng, name in GoogleTranslator.langList[ln] {
                if StrLower(lngName) == StrLower(name) {
                    return lng
                }
            }
        }
        ; if an exact match is not found, we look for a partial one
        for ln in ['sl', 'tl'] {
            for lng, name in GoogleTranslator.langList[ln] {
                if InStr(StrLower(name), StrLower(lngName)) {
                    return lng
                }
            }
        }
        return ''
    }

    static PlayPause(wnd, i, *) {
        if this.HasOwnProp('unsupportedTTSLangs') && this.unsupportedTTSLangs.Has(wnd.lng%i%.Text) {
            this.ShowAudioLanguageError(wnd, i)
            return
        }
        id := wnd.play%i%.hwnd
        if !AudioChannel.channels.Has(id) {
            text := this.GetTextFromField(wnd, i)
            lang := this.LangNameToCode(wnd.lng%i%.Text)
            if lang == '' {
                this.ShowAudioLanguageError(wnd, i)
                return
            }
            AudioChannel.AddChannel(id, text, lang, ObjBindMethod(this, 'OnAudioError', wnd, i))
            this.SetButtonIcon(wnd.play%i%, 'pause', 12)
            SetTimer WaitForPlayStart.Bind(i), 50
        } else {
            channel := AudioChannel.channels[id]
            if channel.HasOwnProp('player') {
                channel.player.Pause()
            } else {
                AudioChannel.RemoveChannel(id)
                return
            }
            if AudioChannel.channels[id].state == 'paused' {
                AudioChannel.channels[id].state := 'playing'
                this.SetButtonIcon(wnd.play%i%, 'pause', 12)
            } else {
                AudioChannel.channels[id].state := 'paused'
                this.SetButtonIcon(wnd.play%i%, 'play', 12)
            }
        }

        WaitForPlayStart(i) {
            try id := wnd.play%i%.hwnd
            catch {
                SetTimer , 0
                return
            }
            if !AudioChannel.channels.Has(id) || (AudioChannel.channels[id].state == 'stopped') {
                this.SetButtonIcon(wnd.play%i%, 'play', 12)
                SetTimer , 0
                return
            }
            if AudioChannel.channels[id].state == 'paused' {
                return
            }
            if AudioChannel.channels[id].state == 'playing' {
                SetTimer , 0
                this.SetButtonIcon(wnd.play%i%, 'pause', 12)
                wnd.stop%i%.Enabled := true
                SetTimer WaitForPlayStop.Bind(i), 50
            }
        }

        WaitForPlayStop(i) {
            try id := wnd.play%i%.hwnd
            catch {
                SetTimer , 0
                return
            }
            if !AudioChannel.channels.Has(id) || AudioChannel.channels[id].state == 'stopped' {
                SetTimer , 0
                this.SetButtonIcon(wnd.play%i%, 'play', 12)
                wnd.stop%i%.Enabled := false
                wnd.txt1.Focus()
                if wnd.edit%i%.Text == '' {
                    wnd.play%i%.Enabled := false
                }
            }
        }
    }

    static ShowAudioLanguageError(wnd, i) {
        currentText := wnd.edit%i%.Text
        shownText := GoogleTranslator.audioErrorTranslatedText
        wnd.edit%i%.Text := shownText
        wnd.play%i%.Enabled := false
        SetTimer ObjBindMethod(this, 'RestoreTextEnablePlay', wnd.edit%i%, currentText, wnd.play%i%, shownText), -2000
    }

    static OnAudioError(wnd, i, errorMsg) {
        try id := wnd.play%i%.hwnd
        catch {
            return
        }
        ; Google rejects an unsupported TTS language with HTTP 400 (reported by
        ; WinHTTP, or by Media Foundation when it opens a URL itself).
        if errorMsg ~= '^(NS_E_BAD_REQUEST|HTTP 400)' {
            errorMsg := 'unsupported language for TTS.'
            if !this.HasOwnProp('unsupportedTTSLangs') {
                this.unsupportedTTSLangs := Map()
            }
            this.unsupportedTTSLangs[wnd.lng%i%.Text] := true
        }
        AudioChannel.RemoveChannel(id)
        this.SetButtonIcon(wnd.play%i%, 'play', 12)
        wnd.stop%i%.Enabled := false
        wnd.play%i%.Enabled := false
        currentText := wnd.edit%i%.Text
        shownText := errorMsg == 'unsupported language for TTS.'
            ? GoogleTranslator.audioErrorTranslatedText
            : 'Playback error: ' . errorMsg
        wnd.edit%i%.Text := shownText
        SetTimer ObjBindMethod(this, 'RestoreTextEnablePlay', wnd.edit%i%, currentText, wnd.play%i%, shownText), -2000
    }

    ; Brings back the text replaced by an audio error message, unless a new
    ; translation or the user's typing has replaced the message meanwhile.
    static RestoreTextEnablePlay(editCtrl, text, playCtrl, shownText) {
        try {
            if editCtrl.Text == shownText {
                editCtrl.Text := text
            }
            playCtrl.Enabled := true
        }
    }

    static Stop(wnd, i) {
        id := wnd.play%i%.hwnd
        if AudioChannel.channels.Has(id) {
            AudioChannel.RemoveChannel(id)
        }
        this.SetButtonIcon(wnd.play%i%, 'play', 12)
        wnd.stop%i%.Enabled := false
        wnd.txt1.Focus()
    }

    static GetTextWidth(fontSize, fontName, text) => this.GetTextSize(fontSize, fontName, text)[1]

    static GetTextHeight(fontSize, fontName, width, text) => this.GetTextSize(fontSize, fontName, text, width)[2]

    static GetTextSize(fontSize, fontName, text, width?) {
        wnd := Gui()
        wnd.SetFont('s' . fontSize, fontName)
        if IsSet(width) {
            wnd.AddEdit('w' . width, text).GetPos(,, &w, &h)
        } else {
            wnd.AddText(, text).GetPos(,, &w, &h)
        }
        wnd.Destroy()
        return [w, h]
    }

    ; Google may report a language that langlist.json does not contain, because
    ; the file is written once and then reused forever. Seen with "mam", which
    ; Google detected in garbled OCR output: the lookup threw UnsetItemError and
    ; killed the thread.
    ;
    ; So on a miss the list is refetched once and the lookup retried. Neither of
    ; these may throw even if the refresh fails or the code is absent upstream
    ; too - showing the bare code beats losing the translation.
    static LangDisplayName(langType, code) {
        list := GoogleTranslator.langList[langType]
        if list.Has(code) {
            return StrTitle(list[code])
        }
        if GoogleTranslator.RefreshLanguages() {
            list := GoogleTranslator.langList[langType]
        }
        return list.Has(code) ? StrTitle(list[code]) : code
    }

    ; Falls back to the first entry, which for 'sl' is "Auto".
    static LangIndex(langType, code) {
        if this.%langType%Indexes.Has(code) {
            return this.%langType%Indexes[code]
        }
        GoogleTranslator.RefreshLanguages()
        return this.%langType%Indexes.Has(code) ? this.%langType%Indexes[code] : 1
    }

    static CreateLangArrays(langList) {
        this.slArr := [], this.tlArr := []
        this.slIndexes := Map()
        this.tlIndexes := Map()
        for langType in ['sl', 'tl'] {
            for k, v in langList[langType] {
                this.%langType%Arr.Push(StrTitle(v))
                this.%langType%Indexes[k] := A_Index
            }
        }
    }

    static OnGuiSize(wnd, minMax, width, height) {
        if !wnd.HasOwnProp('edge') || !wnd.HasOwnProp('coords') || minMax == -1 {
            return
        }
        SetWinDelay 0
        SetControlDelay 0
        this.ResizeHorizontal(wnd, width)
        this.ResizeVertical(wnd, height)
        this.ShedulePosCorrection(wnd, height)
    }

    static ResizeHorizontal(wnd, width) {
        if wnd.edge ~= 'i)left|right' {
            center := width // 2
            Loop 2 {
                i := A_Index
                for ctrl in ['txt', 'lng', 'swapLang'] {
                    wnd.%ctrl . i%.Move(wnd.coords[ctrl . i].x + (width > wnd.coords['center'] * 2 ? center - wnd.coords['center'] : 0))
                }
                wnd.edit%i%.Move(,, width - wnd.MarginX * 2)
                wnd.trans%i%.Move(width - wnd.MarginX - wnd.coords['trans' . i].w + 1)
            }
        }
    }

    static ResizeVertical(wnd, height) {
        if wnd.edge ~= 'i)top' {
            topEditHeight := height - wnd.coords['height'] + wnd.coords['edit1'].h
            if topEditHeight > 60 {
                ResizeTop()
            } else {
                if !this.HasOwnProp('changeResizeMode') {
                    this.changeResizeMode := true
                    this.StoreVerticalCoords(wnd)
                }
                bottomEditHeight := height - wnd.coords['height'] + wnd.coords['edit2'].h
                if bottomEditHeight > 60 {
                    ResizeBottom()
                }
            }
        }
        if wnd.edge ~= 'i)bottom' {
            bottomEditHeight := height - wnd.coords['height'] + wnd.coords['edit2'].h
            if bottomEditHeight > 60 {
                ResizeBottom()
            } else {
                if !this.HasOwnProp('changeResizeMode') {
                    this.changeResizeMode := true
                    this.StoreVerticalCoords(wnd)
                }
                topEditHeight := height - wnd.coords['height'] + wnd.coords['edit1'].h
                if topEditHeight > 60 {
                    ResizeTop()
                }
            }
        }

        ResizeTop() {
            wnd.edit1.Move(,,, topEditHeight)
            wnd.edit1.Redraw()
            for ctrl in ['txt2', 'lng2', 'swapLang2', 'edit2', 'play1', 'stop1', 'trans1', 'play2', 'stop2', 'trans2'] {
                wnd.%ctrl%.Move(, height - wnd.coords['height'] + wnd.coords[ctrl].y)
                wnd.%ctrl%.Redraw()
            }
        }

        ResizeBottom() {
            wnd.edit2.Move(,,, bottomEditHeight)
            wnd.edit2.Redraw()
            for ctrl in ['play2', 'stop2', 'trans2'] {
                wnd.%ctrl%.Move(, height - wnd.coords['height'] + wnd.coords[ctrl].y)
                wnd.%ctrl%.Redraw()
            }
        }
    }

    static ShedulePosCorrection(wnd, height) {
        this.resizeParams.wnd := wnd
        this.resizeParams.height := height
        SetTimer this.adjustLayoutTimer, -50
    }

    static AdjustLayout(params) {
        try {
            params.wnd.edit2.GetPos(, &y)
            params.wnd.edit2.Move(,,, params.height - y - 37)
            for ctrl in ['play2', 'stop2', 'trans2'] {
                params.wnd.%ctrl%.Move(, params.height - 32)
            }
        }
    }

    static StoreHorizontalCoords(wnd) {
        wnd.coords := Map()
        Loop 2 {
            i := A_Index
            for ctrl in ['txt', 'lng', 'swapLang', 'edit', 'play', 'stop', 'trans'] {
                wnd.%ctrl . i%.GetPos(&x,, &w)
                wnd.coords[ctrl . i] := {x: x, w: w}
            }
        }
        guiWidth := wnd.coords['swapLang1'].x + wnd.coords['swapLang1'].w + wnd.MarginX
        wnd.coords['center'] := guiWidth // 2
    }

    static StoreVerticalCoords(wnd) {
        Loop 2 {
            i := A_Index
            for ctrl in ['txt', 'lng', 'swapLang', 'edit', 'play', 'stop', 'trans'] {
                wnd.%ctrl . i%.GetPos(, &y,, &h)
                wnd.coords[ctrl . i].y := y
                wnd.coords[ctrl . i].h := h
            }
        }
        wnd.coords['height'] := wnd.coords['trans2'].y + wnd.coords['trans2'].h + wnd.MarginY
    }
}

class AudioChannel
{
    static channels  := Map()
         ; Media Foundation can build a session whose clock never starts, for
         ; example without an audio endpoint. Waiting for it is bounded.
         , PLAYBACK_START_TIMEOUT := 15000

    static __New() {
        this.InitJScriptEngine()
        this.ConfigureAudioSession()
    }

    ; Speech gets its own audio session. Windows keeps the session volume per
    ; executable and session GUID, so other scripts run by the same
    ; AutoHotkey64.exe neither change the translator's volume nor inherit it.
    ; Keep the GUID unchanged: a new one resets the volume users have set.
    static ConfigureAudioSession() {
        MediaSession.audioSessionId := '{5614E66E-E8D7-421D-9802-51AD909D762E}'
        MediaSession.audioSessionName := 'Google Translate'
        iconFile := AppIconSource.File
        MediaSession.audioSessionIcon := iconFile = A_AhkPath ? '' : iconFile . ',0'
    }

    static AddChannel(id, text, lang, errorCallback) => this.channels[id] := AudioChannel(id, text, lang, errorCallback)

    static RemoveChannel(id) {
        if !this.channels.Has(id) {
            return
        }
        channel := this.channels[id]
        if channel.HasOwnProp('player') {
            try channel.player.Stop()
        }
        channel.state := 'stopped'
        this.channels.Delete(id)
    }

    static InitJScriptEngine() {
        this.JS := LightJson.GetJS()
        this.JS.eval(this.jscript)
    }

    static jscript => '
        (LTrim Join
            var TKK="406398.2087938574";function b(r,t){for(var a=0;a<t.length-2;a+=3){var e="a"<=(e=t.charAt(a+2))?e
            .charCodeAt(0)-87:Number(e);e="+"==t.charAt(a+1)?r>>>e:r<<e;r="+"==t.charAt(a)?r+e&4294967295:r^e}return r}
            function tk(r){for(var t=TKK.split("."),a=Number(t[0])||0,e=[],h=0,n=0;n<r.length;n++){var o=r.charCodeAt(n);
            128>o?e[h++]=o:(2048>o?e[h++]=o>>6|192:(55296==(64512&o)&&n+1<r.length&&56320==(64512&r.charCodeAt(n+1))?
            (o=65536+((1023&o)<<10)+(1023&r.charCodeAt(++n)),e[h++]=o>>18|240,e[h++]=o>>12&63|128):e[h++]=o>>12|224,
            e[h++]=o>>6&63|128),e[h++]=63&o|128)}for(r=a,h=0;h<e.length;h++)r=b(r+=e[h],"+-a^+6");return r=b(r,"+-3^+b+-f"),
            0>(r^=Number(t[1])||0)&&(r=2147483648+(2147483647&r)),(r%=1e6).toString()+"."+(r^a)}
        )'

    static GetGoogleMP3Url(text, lang) {
        return 'https://translate.google.com/translate_tts?ie=UTF-8&tl=' . lang
            . '&total=1&idx=0&client=t&prev=input&textlen=' . StrLen(text)
            . "&tk=" . this.JS.eval('tk')(text) . '&q=' . UrlCodec.Encode(text)
    }

    __New(id, text, lang, errorCallback) {
        this.id := id
        this.errorCallback := errorCallback
        this.wr := WebRequest()
        this.state := 'waiting'
        this.WaitForPlayStartTimer := ObjBindMethod(this, 'WaitForPlayStart')
        this.WaitForPlayEndTimer   := ObjBindMethod(this, 'WaitForPlayEnd')
        SetTimer () => this.StartPlaying(text, lang), -10
        SetTimer this.WaitForPlayStartTimer, 50
        Loop 2 {
            ObjRelease(ObjPtr(this))
        }
    }

    __Delete() {
        Loop 2 {
            ObjAddRef(ObjPtr(this))
        }
        SetTimer this.WaitForPlayStartTimer, 0
        SetTimer this.WaitForPlayEndTimer, 0
        if this.HasProp('player') {
            try this.player.Stop()
            this.DeleteProp('player')
            this.state := 'stopped'
        }
    }

    StartPlaying(text, lang) {
        buf := ''
        
        ; 1. Check the cache (disk and memory)
        buf := GoogleTranslator.cache.GetAudio(text, lang)

        ; 2. Check for an Oxford URL (a URL is known, but no data yet)
        if !buf {
            urlKey := text . '|' . lang
            if GoogleTranslator.oxfordAudioUrls.Has(urlKey) {
                ; One attempt per link: when it fails, Google TTS speaks the
                ; text, now and on later presses.
                oxfordUrl := GoogleTranslator.oxfordAudioUrls.Delete(urlKey)
                try buf := this.wr.Fetch(oxfordUrl).data
                if this.state == 'stopped' {
                    return
                }
                if buf is Buffer && buf.Size {
                    GoogleTranslator.cache.SetAudio(text, lang, buf)
                } else {
                    buf := ''
                }
            }
        }
        
        ; 3. Play
        if buf {
            this.Play(buf)
        } else {
            ; Google TTS: each chunk is downloaded once and played from memory
            urls := []
            for chunk in GoogleTranslator.SmartSplit(text, 200) {
                urls.Push(AudioChannel.GetGoogleMP3Url(chunk, lang))
            }
            this.ttsParts := TtsPartQueue(text, lang, urls, GoogleTranslator.cache, this.wr)
            SetTimer ObjBindMethod(this, 'PlayNextPart'), -30
        }
    }

    PlayNextPart() {
        try nextPart := this.ttsParts.Next()
        catch Error as e {
            SetTimer(() => this.errorCallback.Call(e.Message), -10)
            return
        }
        if this.state != 'stopped' {
            this.Play(nextPart)
        }
    }

    Play(mediaSource) {
        try this.player := this.CreatePlayer(mediaSource)
        catch Error as e {
            SetTimer(() => this.errorCallback.Call(e.Message), -10)
            return
        }
        if !(this.player is AudioPlayer) {
            SetTimer(() => AudioChannel.RemoveChannel(this.id), -10)
            return
        }
        if !this.WaitUntilRunning() {
            this.FailPlayback('playback did not start')
            return
        }
        SetTimer this.WaitForPlayEndTimer, 200
    }

    ; Returns false only on timeout. A channel stopped by the user ends the
    ; wait as well, and that is not a failure.
    WaitUntilRunning() {
        deadline := A_TickCount + AudioChannel.PLAYBACK_START_TIMEOUT
        while this.state != 'stopped' && this.player.state != 'running' {
            if A_TickCount >= deadline {
                return false
            }
            Sleep 10
        }
        return true
    }

    FailPlayback(errorMessage) {
        try this.player.Stop()
        SetTimer(() => this.errorCallback.Call(errorMessage), -10)
    }

    CreatePlayer(mediaSource) {
        MediaSession.lastError := ''
        player := AudioPlayer(mediaSource, '', 'mp3', true, ObjBindMethod(this, 'ShouldCancel'))
        if player.session {
            return player
        }
        if this.state == 'stopped' || MediaSession.lastError == MediaSession.CANCELLED {
            return ''
        }
        throw Error(MediaSession.lastError != ''
                        ? MediaSession.lastError
                        : 'the media session was not created')
    }

    ShouldCancel() => this.state == 'stopped'

    WaitForPlayStart() {
        if this.state == 'stopped' {
            SetTimer , 0
            return
        }
        if !this.HasProp('player') {
            return
        }
        if !(this.player is AudioPlayer) {
            SetTimer , 0
            this.state := 'stopped'
            return
        }
        if this.player.state == 'running' {
            SetTimer , 0
            this.state := 'playing'
        }
    }

    WaitForPlayEnd() {
        hasMoreParts := this.HasOwnProp('ttsParts') && this.ttsParts.HasNext
        if this.player.state == 'running' || this.player.state == 'paused' {
            ; Download the following chunk while this one is playing.
            if hasMoreParts && this.state != 'stopped' {
                this.ttsParts.Prefetch()
            }
            return
        }
        SetTimer(, 0)
        if hasMoreParts && this.state != 'stopped' {
            try {
                nextPart := this.ttsParts.Next()
                nextPlayer := this.state == 'stopped' ? '' : this.CreatePlayer(nextPart)
            } catch Error as e {
                SetTimer(() => this.errorCallback.Call(e.Message), -10)
                return
            }
            if !(nextPlayer is AudioPlayer) {
                SetTimer(() => AudioChannel.RemoveChannel(this.id), -10)
                return
            }
            this.player := nextPlayer
            if !this.WaitUntilRunning() {
                this.FailPlayback('playback did not start')
                return
            }
            SetTimer , 100
        } else if this.state != 'stopped' {
            SetTimer(() => AudioChannel.RemoveChannel(this.id), -10)
        }
    }
}

; Google TTS chunks of one text. Each chunk is downloaded once and played from
; memory; the next one is fetched while the current one plays. When the last
; chunk has arrived, the whole recording goes to the cache.
class TtsPartQueue
{
    __New(text, lang, urls, audioCache, requestClient := '') {
        this.text := text
        this.lang := lang
        this.urls := urls.Clone()
        this.audioCache := audioCache
        this.wr := requestClient ? requestClient : WebRequest()
        this.parts := []
        this.prefetched := ''
        this.prefetchFailed := false
    }

    HasNext => IsObject(this.prefetched) || this.urls.Length > 0

    ; Returns the next chunk, downloading it unless it has been prefetched.
    Next() {
        if IsObject(this.prefetched) {
            nextPart := this.prefetched
            this.prefetched := ''
            return nextPart
        }
        this.prefetchFailed := false
        return this._Download()
    }

    ; A failed prefetch is not reported: Next() retries the download and
    ; reports the error if it fails again.
    Prefetch() {
        if IsObject(this.prefetched) || this.prefetchFailed || !this.urls.Length {
            return
        }
        try {
            this.prefetched := this._Download()
        } catch {
            this.prefetchFailed := true
        }
    }

    _Download() {
        if !this.urls.Length {
            throw Error('No more audio parts')
        }
        audioPart := this.wr.Fetch(this.urls[1]).data
        if !(audioPart is Buffer) || !audioPart.Size {
            throw Error('Empty audio response')
        }
        this.urls.RemoveAt(1)
        this.parts.Push(audioPart)
        if !this.urls.Length {
            this._StoreInCache()
        }
        return audioPart
    }

    ; MP3 frames are self-contained, so the chunks are joined into one file.
    _StoreInCache() {
        totalSize := 0
        for audioPart in this.parts {
            totalSize += audioPart.Size
        }
        recording := Buffer(totalSize)
        offset := 0
        for audioPart in this.parts {
            DllCall('RtlMoveMemory', 'Ptr', recording.Ptr + offset, 'Ptr', audioPart, 'Ptr', audioPart.Size)
            offset += audioPart.Size
        }
        try this.audioCache.SetAudio(this.text, this.lang, recording)
    }
}

class WinEventHook
{
    ; Event Constants: https://is.gd/tRT5Wr
    __New(eventMin, eventMax, hookProc, options := '', idProcess := 0, idThread := 0, dwFlags := 0) {
        this.pCallback := CallbackCreate(hookProc, options, 7)
        this.hHook := DllCall('SetWinEventHook', 'UInt', eventMin, 'UInt', eventMax, 'Ptr', 0, 'Ptr', this.pCallback
                                               , 'UInt', idProcess, 'UInt', idThread, 'UInt', dwFlags, 'Ptr')
    }
    __Delete() {
        DllCall('UnhookWinEvent', 'Ptr', this.hHook)
        CallbackFree(this.pCallback)
    }
}

class HtmlCodec
{
    static Encode(text) {
        static pairs := [ [ '&',  '&amp;'  ],
                          [ '<',  '&lt;'   ],
                          [ '>',  '&gt;'   ],
                          [ '"',  '&quot;' ],
                          [ "'",  '&#39;'  ] ]
        for item in pairs {
            text := StrReplace(text, item[1], item[2])
        }
        return RegExReplace(text, '\R', '<br>')
    }

    static Decode(html) {
        static pairs := [ [ '&quot;', '"' ],
                          [ '&#39;' , "'" ],
                          [ '&apos;', "'" ],
                          [ '&lt;'  , '<' ],
                          [ '&gt;'  , '>' ],
                          [ '&nbsp;', ' ' ],
                          [ '&amp;' , '&' ] ]
        html := RegExReplace(html, 'i)<br\s*/?>', '`r`n')
        for item in pairs {
            html := StrReplace(html, item[1], item[2])
        }
        return html
    }
}

class UrlCodec
{
    static __New() => this.JS := LightJson.GetJS()
    static Encode(str, component := true) => this.JS.%'encodeURI' . (component ? 'Component' : '')%(str)
    static Decode(str, component := true) => this.JS.%'decodeURI' . (component ? 'Component' : '')%(str)
}

class WebRequest
{
    __New() => this.DefineProp('whr', {value: ComObject('WinHttp.WinHttpRequest.5.1')})
    __Get(key, params)        => this.whr.%key%[params*]
    __Set(key, params, value) => this.whr.%key%[params*] := value
    __Call(name, params)      => this.whr.%name%(params*)
    __Delete() => this.whr := ''

    status => this.whr.status
    statusText => this.whr.StatusText

    Fetch(url, method := 'GET', HeadersMap := '', body := '', timeouts := '', waitTimeoutSec := 30) {
        ; A response object must retain its own WinHTTP request. Reusing one COM
        ; object made an older response read the body of the most recent Fetch.
        request := ComObject('WinHttp.WinHttpRequest.5.1')
        this.whr := request

        try {
            request.Open(method, url, true)

            if timeouts is Array {
                if timeouts.Length != 4 {
                    throw ValueError('WebRequest timeouts must contain four values')
                }
                request.SetTimeouts(timeouts[1], timeouts[2], timeouts[3], timeouts[4])
            } else {
                ; resolve, connect, send, receive (ms)
                request.SetTimeouts(10000, 10000, 20000, 20000)
            }

            if HeadersMap is Map {
                for name, value in HeadersMap {
                    request.SetRequestHeader(name, value)
                }
            }

            request.Send(body)

            if !request.WaitForResponse(waitTimeoutSec) {
                throw Error('WebRequest timeout')
            }

            status := request.Status
            if status < 200 || status >= 300 {
                statusText := request.StatusText
                throw Error('HTTP ' . status . (statusText == '' ? '' : ' ' . statusText))
            }

            res := {}
            res.DefineProp('text', {Get: GetData.Bind(request, 'text')})
            res.DefineProp('data', {Get: GetData.Bind(request, 'data')})
            res.DefineProp('__Get' , {Call: (s, p, *) => request.%p%})
            res.DefineProp('__Call', {Call: (s, m, p) => request.%m%(p*)})
            return res
        } catch Error as requestError {
            try request.Abort()
            throw requestError
        }

        static GetData(request, mode, *) {
            if !safeArray := request.responseBody
                return ''

            pData := NumGet(ComObjValue(safeArray) + 8 + A_PtrSize, 'Ptr')
            size := safeArray.MaxIndex() + 1

            if mode = 'text'
                return StrGet(pData, size, 'UTF-8')

            DllCall('RtlMoveMemory', 'Ptr', buf := Buffer(size), 'Ptr', pData, 'Ptr', size)
            return buf
        }
    }
}

class LightJson
{
    static JS := LightJson.GetJS(), true := {}, false := {}, null := {}

    static Parse(json, objIsMap := true, _rec?) {
        switch {
            case !IsSet(_rec)    : obj := this.Parse(this.JS.JSON.parse(json), objIsMap, true)
            case !IsObject(json) : obj := json
            case this.JS.Object.prototype.toString.call(json) == '[object Array]':
                obj := []
                Loop json.length {
                    obj.Push(this.Parse(json.%A_Index - 1%, objIsMap, true))
                }
            default:
                obj := objIsMap ? LinkedOrderedMap() : {}
                keys := this.JS.Object.keys(json)
                Loop keys.length {
                    k := keys.%A_Index - 1%
                    objIsMap ? obj[k]  := this.Parse(json.%k%, true , true)
                             : obj.%k% := this.Parse(json.%k%, false, true)
                }
        }
        return obj
    }

    static Stringify(obj, indent := '') {
        if indent = true {
            for k, v in ['true', 'false', 'null']
                if (obj = this.%v%)
                    return v

            if IsObject(obj) {
                isArray := Type(obj) = 'Array'
                enumerable := Type(obj) = 'Object' ? obj.OwnProps() : obj
                str := ''
                for k, v in enumerable
                    str .= (A_Index = 1 ? '' : ',') . (isArray ? '' : this.Stringify(k, true) . ':') . this.Stringify(v, true)

                return isArray ? '[' str ']' : '{' str '}'
            }
            if IsNumber(obj) && Type(obj) != 'String'
                return obj

            for k, v in [['\', '\\'], [A_Tab, '\t'], ['"', '\"'], ['/', '\/'], ['`n', '\n'], ['`r', '\r'], [Chr(12), '\f'], [Chr(8), '\b']]
                obj := StrReplace(obj, v[1], v[2])

            return '"' obj '"'
        }
        sObj := this.Stringify(obj, true)
        return this.JS.eval('JSON.stringify(' . sObj . ',"","' . indent . '")')
    }

    ; The text may come from the network: it is parsed as data, never evaluated.
    static Beautify(json, indent) => this.JS.JSON.stringify(this.JS.JSON.parse(json), '', indent)

    static GetJS() {
        static document := '', JS
        if !document {
            document := ComObject('HTMLFILE')
            document.write('<meta http-equiv="X-UA-Compatible" content="IE=9">')
            JS := document.parentWindow
            (document.documentMode < 9 && JS.execScript())
        }
        return JS
    }
}

class LinkedOrderedMap
{
    Default := unset
    _store := Map()    ; key -> value (native Map)
    _pos   := Map()    ; key -> index in _order
    _order := []       ; keys in insertion order (with "holes" after Delete)
    _caseSense := 'On'
    _holes := 0
    _compactThreshold := 0.30   ; 30% holes -> Compact()

    __New(keyValueList*) => this.Set(keyValueList*)

    CaseSense {
        get => this._caseSense
        set {
            if this._store.Count
                throw ValueError('Map must be empty')
            this._caseSense := (value = 'On' || value = true) ? 'On' : 'Off'
            this._store.CaseSense := this._caseSense
            this._pos.CaseSense   := this._caseSense
            return this._caseSense
        }
    }

    Count => this._store.Count

    Clear() {
        this._store := Map(), this._store.CaseSense := this._caseSense
        this._pos   := Map(), this._pos.CaseSense   := this._caseSense
        this._order := []
        this._holes := 0
    }

    Has(key) => this._store.Has(key)

    Get(key, default?) {
        switch {
            case this._pos.Has(key)      : return this._store[key]
            case IsSet(default)          : return default
            case this.HasProp('Default') : return this.Default
            default                      : throw UnsetItemError('Map has no such key',, key)
        }
    }

    Set(keyValueList*) {
        if Mod(keyValueList.Length, 2)
            throw ValueError('Incorrect keyValueList: the number of elements must be even!')
        for i, v in keyValueList {
            if Mod(i, 2)
                key := v
            else
                this[key] := v
        }
        return this
    }

    __Item[key] {
        get => this.Get(key)
        set {
            if this._pos.Has(key)
                return this._store[key] := value

            idx := this._order.Length + 1
            this._order.Push(key)
            this._pos[key] := idx
            this._store[key] := value
            return value
        }
    }

    Delete(key) {
        if !this._pos.Has(key)
            throw UnsetItemError('Map has no such key',, key)
        idx := this._pos[key]
        val := this._store.Delete(key)
        this._pos.Delete(key)
        this._order.Delete(idx)   ; make a "hole", don't touch the order of the rest
        this._holes += 1
        this._MaybeCompact()
        return val
    }

    __Enum(n) {
        arr := this._order
        store := this._store
        len := arr.Length, i := 0
        return (&a, &b?) => (
            i := LinkedOrderedMap._NextOccupied(arr, i, len),
            i > len ? false : (
                a := arr[i],
                (n == 2 && b := store[a]),
                true
            )
        )
    }

    Compact() {
        newOrder := []
        newPos := Map()
        newPos.CaseSense := this._caseSense
        Loop this._order.Length {
            if !this._order.Has(A_Index)
                continue
            k := this._order[A_Index]
            newOrder.Push(k)
            newPos[k] := newOrder.Length
        }
        this._order := newOrder
        this._pos := newPos
        this._holes := 0
    }

    _MaybeCompact() {
        if !(len := this._order.Length)
            return
        if (this._holes / len) >= this._compactThreshold
            this.Compact()
    }

    static _NextOccupied(arr, i, len) {
        while (++i <= len && !arr.Has(i))
            continue
        return i
    }
}

class BinaryEncoder
{
    static CryptBinaryToString(data, size?, formatName := 'CRYPT_STRING_BASE64', NOCRLF := true)
    {
        static formats := { CRYPT_STRING_BASE64: 0x1,
                            CRYPT_STRING_HEX:    0x4,
                            CRYPT_STRING_HEXRAW: 0xC }
            , CRYPT_STRING_NOCRLF := 0x40000000

        sz := size ?? data.size
        fmt := formats.%formatName% | (NOCRLF ? CRYPT_STRING_NOCRLF : 0)
        if !DllCall('Crypt32\CryptBinaryToString', 'Ptr', data, 'UInt', sz, 'UInt', fmt, 'Ptr', 0, 'UIntP', &chars := 0)
            throw OSError()
        VarSetStrCapacity(&outString, chars)
        DllCall('Crypt32\CryptBinaryToString', 'Ptr', data, 'UInt', sz, 'UInt', fmt, 'Str', outString, 'UIntP', &chars)
        return outString
    }

    static CryptStringToBinary(string, formatName := 'CRYPT_STRING_BASE64')
    {
        static formats := { CRYPT_STRING_BASE64: 0x1,
                            CRYPT_STRING_HEX:    0x4,
                            CRYPT_STRING_HEXRAW: 0xC }
        fmt := formats.%formatName%
        chars := StrLen(string)
        if !DllCall('Crypt32\CryptStringToBinary', 'Str', string, 'UInt', chars, 'UInt', fmt
                                                , 'Ptr', 0, 'UIntP', &bytes := 0, 'UIntP', 0, 'UIntP', 0)
            throw OSError()
        outBuf := Buffer(bytes, 0)
        DllCall('Crypt32\CryptStringToBinary', 'Str', string, 'UInt', chars, 'UInt', fmt
                                            , 'Ptr', outBuf, 'UIntP', &bytes, 'UIntP', 0, 'UIntP', 0)
        return outBuf
    }
}

class CyclicDB
{ ; CyclicDB is a circular database (ring buffer).
  ; The file is kept open for the lifetime of the object to prevent
  ; cloud sync services (OneDrive, Dropbox, etc.) from locking it
  ; between discrete open/close calls.

    static MAGIC             := 0x43444243  ; "CDBC" — CyclicDB Cache
    static VERSION           := 1
    static HEADER_SIZE       := 18          ; global header size
    static RECORD_HEADER_SIZE := 12         ; record header size
    static RECORD_MARKER     := 0xFACE      ; record start marker
    static RECORD_DELETED    := 0xDEAD      ; soft-deleted record marker
    static RECORD_LAP_END    := 0xE0F0      ; end of the older lap (see Set)

    ; Layout. Records run from HEADER_SIZE to head while the ring is linear.
    ; Once a record does not fit before maxSize, the ring wraps: the end of
    ; the current lap is marked with RECORD_LAP_END and writing goes on from
    ; HEADER_SIZE. Then the live records are the older lap, from tail to its
    ; marker (or the end of the file), followed by the newer one, from
    ; HEADER_SIZE to head. Bytes after the marker are left over from earlier
    ; laps. Files written before the marker existed end a lap with such bytes;
    ; a header there that is not a record is taken for the lap end as well.

    path    := ''
    maxSize := 0
    head    := 0
    tail    := 0
    wrapped := false
    index   := Map()
    _file   := ''   ; persistent file handle (opened in Open, closed in __Delete)
    _readOnly := false   ; true → open 'r', skip recovery/create (search worker)

    ; ── Lifecycle ────────────────────────────────────────────────────────────

    ; Open or create the database. Keeps the file handle open until Close().
    ; readOnly=true opens the file with 'r' and never writes (no crash recovery,
    ; no create, no header write). Used by the out-of-process search worker so it
    ; can read concurrently with the main process's 'rw' handle.
    Open(path, maxSize, readOnly := false) {
        this.path      := path
        this.index     := Map()
        this._readOnly := readOnly

        ; Recover from a crashed Compact (a write) — skip in read-only mode.
        if !readOnly && !FileExist(path) && FileExist(path . '.bak')
            try FileMove(path . '.bak', path)

        if FileExist(path) && this._ReadGlobalHeader() {
            this._BuildIndex()
        } else if readOnly {
            ; Nothing valid to read and we must not write — start empty.
            this.maxSize := maxSize
            this.head    := CyclicDB.HEADER_SIZE
            this.tail    := CyclicDB.HEADER_SIZE
            this.wrapped := false
        } else {
            this.maxSize := maxSize
            this._CreateNew()
        }
        return this
    }

    ; Close the file handle and clear the index.
    Close() {
        if this._file {
            this._file.Close()
            this._file := ''
        }
        this.index := Map()
    }

    __Delete() => this.Close()

    Clear() => this._CreateNew()

    Has(key) => this.index.Has(key)

    ; ── Public API ───────────────────────────────────────────────────────────

    ; Soft-delete: overwrites the record marker with RECORD_DELETED.
    ; An index entry that no longer matches the record at its offset is only
    ; dropped: writing there would damage the record that lives there now.
    Delete(key) {
        if !this.index.Has(key)
            return false

        entry := this.index[key]
        file  := this._file
        if !file || this._readOnly
            return false

        if !this._RecordMatches(file, entry, key) {
            this.index.Delete(key)
            return true
        }

        this._WriteUShortAt(file, entry.offset, CyclicDB.RECORD_DELETED)

        ; Zero out payload to wipe sensitive data. Header fields (marker,
        ; keyLength, dataLength, crc) and key bytes are preserved so that
        ; the walk over the ring can still step past this record.
        if entry.dataLength > 0 {
            static CHUNK := 65536, zeros := Buffer(CHUNK, 0)
            file.Seek(entry.offset + CyclicDB.RECORD_HEADER_SIZE + entry.keyLength)
            remaining := entry.dataLength
            while remaining > 0 {
                want    := Min(remaining, CHUNK)
                written := file.RawWrite(zeros, want)
                if written <= 0
                    break   ; defensive: avoid infinite loop on persistent failure
                remaining -= written
            }
        }

        this.index.Delete(key)
        return true
    }

    ; Read a record by key. Returns the data Buffer, or '' if not found.
    Get(key, &found := false) {
        found := false

        if !this.index.Has(key)
            return ''

        file := this._file
        if !file
            return ''

        entry := this.index[key]

        try {
            off := entry.offset

            if off < CyclicDB.HEADER_SIZE || off + CyclicDB.RECORD_HEADER_SIZE > file.Length
                return ''

            file.Seek(off)

            marker := file.ReadUShort()
            if marker != CyclicDB.RECORD_MARKER
                return ''

            keyLength  := file.ReadUShort()
            dataLength := file.ReadUInt()
            crc        := file.ReadUInt()

            recordSize := CyclicDB.RECORD_HEADER_SIZE + keyLength + dataLength
            if keyLength = 0 || recordSize <= CyclicDB.RECORD_HEADER_SIZE
                return ''
            if off + recordSize > file.Length
                return ''
            if keyLength != entry.keyLength || dataLength != entry.dataLength
                return ''

            keyBuf := Buffer(keyLength)
            if file.RawRead(keyBuf) != keyLength
                return ''

            keyRead := StrGet(keyBuf, 'UTF-8')
            if keyRead != key
                return ''

            dataBuf := Buffer(dataLength)
            if file.RawRead(dataBuf) != dataLength
                return ''

            if this._ComputeCRC(keyBuf, dataBuf) != crc
                return ''

            found := true
            return dataBuf
        }
    }

    ; Fast read of a record's value (type byte + payload) WITHOUT CRC or key
    ; verification. Uses the in-memory index offset directly. Intended for the
    ; search scan path, where integrity is trusted and per-record CRC over the
    ; whole DB is the dominant cost. Returns a Buffer, or '' if not found.
    ReadValueNoVerify(key) {
        if !this.index.Has(key)
            return ''
        file := this._file
        if !file
            return ''
        entry := this.index[key]
        try {
            if entry.dataLength = 0
                return ''
            file.Seek(entry.offset + CyclicDB.RECORD_HEADER_SIZE + entry.keyLength)
            buf := Buffer(entry.dataLength)
            if file.RawRead(buf) != entry.dataLength
                return ''
            return buf
        }
        return ''
    }

    ; Returns true if a record with this key and a value of `valueSize` bytes
    ; would fit the ring at all — i.e. Set() would NOT throw "record too large".
    ; Mirrors the guard in Set so callers can pre-check instead of catching.
    CanStore(key, valueSize) {
        keyLength  := this._StringToUTF8(key).Size
        recordSize := CyclicDB.RECORD_HEADER_SIZE + keyLength + valueSize
        return recordSize <= this.maxSize - CyclicDB.HEADER_SIZE
    }

    ; Reads just the first payload byte (the record's type tag) via the
    ; persistent handle, without loading the whole value. Returns the byte, or
    ; -1 if the key is unknown or the handle is unavailable.
    ReadTypeByte(key) {
        if !this.index.Has(key)
            return -1
        file := this._file
        if !file
            return -1
        entry := this.index[key]
        try {
            file.Seek(entry.offset + CyclicDB.RECORD_HEADER_SIZE + entry.keyLength)
            return file.ReadUChar()
        }
        return -1
    }

    ; Write a key/value pair. Evicts old records if the ring is full.
    ; If returnEvicted=true, returns Array of {key, value: Buffer} for each evicted record.
    ; Otherwise returns an empty array.
    ; Throws if the record is larger than the ring can ever hold — callers that
    ; accept untrusted-size input should pre-check with CanStore() — and when
    ; the file cannot be written; the index then lists intact records only.
    Set(key, value, returnEvicted := false) {
        keyBuf     := this._StringToUTF8(key)
        keyLength  := keyBuf.Size
        dataBuf    := value is String ? this._StringToUTF8(value) : value
        dataLength := dataBuf.Size
        recordSize := CyclicDB.RECORD_HEADER_SIZE + keyLength + dataLength

        if recordSize > this.maxSize - CyclicDB.HEADER_SIZE
            throw Error('The record is too large for the database.')
        if this._readOnly
            throw Error('The database is open read-only.')

        if !FileExist(this.path)
            this._CreateNew()
        file := this._file
        if !file
            throw Error('Failed to open file for writing')

        evicted    := []
        oldTail    := this.tail
        oldWrapped := this.wrapped

        if this.head + recordSize > this.maxSize {
            ; No room before the end of the file: a new lap starts at the
            ; beginning. What is left of the older lap is evicted first. Then
            ; the end of the current lap is marked: the bytes after it are left
            ; over from earlier laps and must not be read as records.
            while this.wrapped
                this._PushEvicted(evicted, this._AdvanceTail(returnEvicted))
            this._MarkLapEnd(file, this.head)
            this.wrapped := true
            this.head    := CyclicDB.HEADER_SIZE
        }
        while this.wrapped && this.head + recordSize > this.tail
            this._PushEvicted(evicted, this._AdvanceTail(returnEvicted))

        ; Persist the eviction before the new record overwrites evicted data:
        ; after a crash in between, the header points at intact records only.
        if this.tail != oldTail || this.wrapped != oldWrapped
            this._WriteGlobalHeader(file)

        this._WriteRecordAt(file, this.head, keyBuf, dataBuf, this._ComputeCRC(keyBuf, dataBuf))
        this.index[key] := {
            offset:     this.head,
            keyLength:  keyLength,
            dataLength: dataLength
        }
        this.head += recordSize
        this._WriteGlobalHeader(file)

        return evicted
    }

    ; Rebuild the database with a new maximum size.
    ; pinnedKeys — array of keys protected from eviction when shrinking.
    ; Returns:
    ;   {ok: true,  evicted: [keys]}        — success (evicted may be empty)
    ;   {ok: false, minRequired: bytes}     — pinned data does not fit
    Resize(newMaxSize, pinnedKeys := []) {
        if newMaxSize < CyclicDB.HEADER_SIZE + CyclicDB.RECORD_HEADER_SIZE
            throw Error('The new size is too small')

        pinnedSet      := this._KeysToSet(pinnedKeys)
        pinnedLiveSize := 0
        liveSize       := 0
        for key, entry in this.index {
            recSize  := CyclicDB.RECORD_HEADER_SIZE + entry.keyLength + entry.dataLength
            liveSize += recSize
            if pinnedSet.Has(key)
                pinnedLiveSize += recSize
        }

        capacity := newMaxSize - CyclicDB.HEADER_SIZE
        if pinnedLiveSize > capacity
            return {ok: false, minRequired: pinnedLiveSize + CyclicDB.HEADER_SIZE}

        evictionTargetSize := (liveSize <= capacity) ? 0 : capacity
        return this.Compact(newMaxSize, pinnedKeys, evictionTargetSize)
    }

    ; Rewrite the database file, dropping soft-deleted records and optionally
    ; evicting oldest non-pinned records to fit evictionTargetSize bytes of
    ; live payload (RECORD_HEADER + key + data, summed).
    ; evictionTargetSize=0 means "no eviction, keep everything live".
    ; Returns {ok: true, evicted: [keys]}. On failure it throws, and the
    ; database is restored from the backup copy together with its index.
    Compact(newMaxSize, pinnedKeys := [], evictionTargetSize := 0) {
        if newMaxSize < CyclicDB.HEADER_SIZE + CyclicDB.RECORD_HEADER_SIZE
            throw Error('The new size is too small')
        if this._readOnly
            throw Error('The database is open read-only.')

        ; Empty index — just recreate with the new size.
        if this.index.Count = 0 {
            this.maxSize := newMaxSize
            this._CreateNew()
            return {ok: true, evicted: []}
        }

        ; Fast path: nothing to do. Conditions:
        ;   - size unchanged
        ;   - no eviction requested
        ;   - DB is linear (not wrapped)
        ;   - file contains only live records (no soft-delete gaps),
        ;     i.e. live payload exactly fills [HEADER_SIZE, head).
        ; Skips FileMove, .bak creation, full file rewrite.
        if newMaxSize = this.maxSize && evictionTargetSize = 0 && !this.wrapped {
            liveSize := 0
            for key, entry in this.index
                liveSize += CyclicDB.RECORD_HEADER_SIZE + entry.keyLength + entry.dataLength
            if liveSize = this.head - CyclicDB.HEADER_SIZE
                return {ok: true, evicted: []}
        }

        previous := {head: this.head, tail: this.tail, wrapped: this.wrapped, maxSize: this.maxSize}
        bakPath  := this.path . '.bak'

        ; Close the persistent handle before moving the file
        this.Close()

        try FileMove(this.path, bakPath, true)
        catch {
            this._Reload()
            throw Error('Compact: failed to move db to .bak')
        }

        try {
            evictedKeys := this._CopyFromBackup(bakPath, previous, newMaxSize,
                                                this._KeysToSet(pinnedKeys), evictionTargetSize)
        } catch Error as copyError {
            ; Roll back: the backup still holds every record.
            this.Close()
            try FileDelete(this.path)
            try FileMove(bakPath, this.path, true)
            this.maxSize := previous.maxSize
            this._Reload()
            throw Error('Compact: ' . copyError.Message . '; the database was restored from .bak')
        }

        try FileDelete(bakPath)
        return {ok: true, evicted: evictedKeys}
    }

    ; Copies the live records of the backup file, oldest first, into a new
    ; database of newMaxSize bytes and returns the keys evicted to fit
    ; evictionTargetSize. Throws on any read or write error.
    _CopyFromBackup(bakPath, previous, newMaxSize, pinnedSet, evictionTargetSize) {
        bakFile := FileOpen(bakPath, 'r')
        if !bakFile
            throw Error('failed to open .bak for reading')
        try {
            scan := this._ScanHeaders(bakFile, previous.head, previous.tail,
                                      previous.wrapped, previous.maxSize)
            ; A damaged header in the older lap only ends that lap; one in the
            ; newer part would lose records.
            if scan.badOffset
                throw Error('corrupted record at offset ' . scan.badOffset)

            ; First pass: keys of the live records. A key written again later
            ; keeps only its newest record.
            liveRecords := []
            newestByKey := Map()
            for rec in scan.records {
                if rec.deleted
                    continue
                keyBuf := Buffer(rec.keyLength)
                bakFile.Seek(rec.offset + CyclicDB.RECORD_HEADER_SIZE)
                if bakFile.RawRead(keyBuf) != rec.keyLength
                    throw Error('failed to read a key at offset ' . rec.offset)
                rec.keyBuf := keyBuf
                rec.key    := StrGet(keyBuf, 'UTF-8')
                rec.pinned := pinnedSet.Has(rec.key)
                liveRecords.Push(rec)
                newestByKey[rec.key] := liveRecords.Length
            }
            survivors := []
            totalLive := 0
            for i, rec in liveRecords {
                if newestByKey[rec.key] = i {
                    survivors.Push(rec)
                    totalLive += rec.size
                }
            }

            ; Drop the oldest non-pinned records until the live payload fits
            ; evictionTargetSize. When evictionTargetSize=0, no eviction.
            evictedKeys := []
            skipped     := Map()
            if evictionTargetSize > 0 {
                for i, rec in survivors {
                    if totalLive <= evictionTargetSize
                        break
                    if rec.pinned
                        continue
                    skipped[i] := true
                    evictedKeys.Push(rec.key)
                    totalLive -= rec.size
                }
            }

            ; Second pass: copy the surviving records into the new file. A
            ; record whose checksum fails is dropped instead of copied.
            this.maxSize := newMaxSize
            this._CreateNew()   ; reopens _file
            for i, rec in survivors {
                if skipped.Has(i)
                    continue
                dataBuf := Buffer(rec.dataLength)
                bakFile.Seek(rec.offset + CyclicDB.RECORD_HEADER_SIZE + rec.keyLength)
                if rec.dataLength > 0 && bakFile.RawRead(dataBuf) != rec.dataLength
                    throw Error('failed to read data at offset ' . rec.offset)
                if this._ComputeCRC(rec.keyBuf, dataBuf) != rec.crc
                    continue
                if this.head + rec.size > this.maxSize
                    throw Error('the records do not fit the new size')
                this._WriteRecordAt(this._file, this.head, rec.keyBuf, dataBuf, rec.crc)
                this.index[rec.key] := {
                    offset:     this.head,
                    keyLength:  rec.keyLength,
                    dataLength: rec.dataLength
                }
                this.head += rec.size
            }
            this._WriteGlobalHeader(this._file)
        } finally {
            bakFile.Close()
        }
        return evictedKeys
    }

    ; ── Private ──────────────────────────────────────────────────────────────

    _CreateNew() {
        if this._readOnly
            throw Error('The database is open read-only.')
        this.head    := CyclicDB.HEADER_SIZE
        this.tail    := CyclicDB.HEADER_SIZE
        this.wrapped := false
        this.index   := Map()

        ; Close existing handle before truncating
        if this._file {
            this._file.Close()
            this._file := ''
        }

        file := FileOpen(this.path, 'w')
        if !file
            throw Error('Failed to create database file')
        this._WriteGlobalHeader(file)
        file.Close()

        this._OpenFile()
    }

    ; Open (or reopen) the persistent read-write handle.
    _OpenFile() {
        if this._file {
            this._file.Close()
            this._file := ''
        }
        file := FileOpen(this.path, this._readOnly ? 'r' : 'rw')
        if !file
            throw Error('Failed to open database file: ' this.path)
        this._file := file
    }

    _ReadGlobalHeader() {
        if !FileExist(this.path)
            return false

        file := FileOpen(this.path, 'r')
        if !file
            return false

        if file.Length < CyclicDB.HEADER_SIZE {
            file.Close()
            return false
        }

        magic := file.ReadUInt()
        if magic != CyclicDB.MAGIC {
            file.Close()
            return false
        }

        version := file.ReadUChar()
        if version != CyclicDB.VERSION {
            file.Close()
            return false
        }

        this.maxSize := file.ReadUInt()
        this.head    := file.ReadUInt()
        this.tail    := file.ReadUInt()
        this.wrapped := file.ReadUChar() != 0

        file.Close()

        ; Now open the persistent handle
        this._OpenFile()
        return true
    }

    _WriteGlobalHeader(file) {
        static header := Buffer(CyclicDB.HEADER_SIZE)
        NumPut('UInt',  CyclicDB.MAGIC, 'UChar', CyclicDB.VERSION, 'UInt', this.maxSize,
               'UInt',  this.head,      'UInt',  this.tail,
               'UChar', this.wrapped ? 1 : 0, header)
        file.Seek(0)
        this._WriteChecked(file, header)
    }

    ; Reopens the file at this.path and rebuilds the index from it.
    _Reload() {
        this.index := Map()
        if !this._ReadGlobalHeader()
            throw Error('Failed to reopen the database file: ' . this.path)
        this._BuildIndex()
    }

    _BuildIndex() {
        this.index := Map()
        file       := this._file
        if !file {
            if !this._readOnly
                this._CreateNew()
            return
        }

        scan := this._ScanHeaders(file, this.head, this.tail, this.wrapped, this.maxSize)
        for rec in scan.records {
            if rec.deleted
                continue
            keyBuf  := Buffer(rec.keyLength)
            dataBuf := Buffer(rec.dataLength)
            file.Seek(rec.offset + CyclicDB.RECORD_HEADER_SIZE)
            if file.RawRead(keyBuf) != rec.keyLength
                || (rec.dataLength > 0 && file.RawRead(dataBuf) != rec.dataLength)
                || this._ComputeCRC(keyBuf, dataBuf) != rec.crc {
                ; A damaged record is dropped on its own: its header still
                ; gives the size, so the records after it stay reachable.
                if !this._readOnly
                    try this._WriteUShortAt(file, rec.offset, CyclicDB.RECORD_DELETED)
                continue
            }
            this.index[StrGet(keyBuf, 'UTF-8')] := {
                offset:     rec.offset,
                keyLength:  rec.keyLength,
                dataLength: rec.dataLength
            }
        }

        if this._readOnly
            return
        ; The older lap ends at its damaged header, so it gets the marker there.
        if scan.lapEndAt
            try this._WriteUShortAt(file, scan.lapEndAt, CyclicDB.RECORD_LAP_END)
        ; Nothing after a damaged header in the newer part can be walked: new
        ; records go there.
        if scan.badOffset {
            this.head := scan.badOffset
            try this._WriteGlobalHeader(file)
        }
    }

    ; Walks the record headers in logical order, oldest first, without reading
    ; keys or data. Returns {records, lapEndAt, badOffset}. A damaged header in
    ; the older lap ends that lap - files written before lap-end markers end
    ; it with leftover bytes - and the walk goes on with the newer lap;
    ; lapEndAt is where that happened, or 0. A damaged header in the newer
    ; part stops the walk; badOffset is where, or 0 when the walk reached head.
    _ScanHeaders(file, head, tail, wrapped, maxSize) {
        records    := []
        lapEndAt   := 0
        pos        := tail
        inOldLap   := wrapped
        fileLength := file.Length
        loop {
            if inOldLap {
                if this._IsLapEnd(file, pos, maxSize) {
                    pos      := CyclicDB.HEADER_SIZE
                    inOldLap := false
                    continue
                }
                limit := Min(maxSize, fileLength)
            } else {
                if pos >= head
                    break
                limit := Min(head, fileLength)
            }

            damaged := pos + CyclicDB.RECORD_HEADER_SIZE > limit
            if !damaged {
                file.Seek(pos)
                marker     := file.ReadUShort()
                keyLength  := file.ReadUShort()
                dataLength := file.ReadUInt()
                crc        := file.ReadUInt()
                recordSize := CyclicDB.RECORD_HEADER_SIZE + keyLength + dataLength
                damaged := (marker != CyclicDB.RECORD_MARKER && marker != CyclicDB.RECORD_DELETED)
                           || keyLength = 0 || pos + recordSize > limit
            }
            if damaged {
                if !inOldLap
                    return {records: records, lapEndAt: lapEndAt, badOffset: pos}
                lapEndAt := pos
                pos      := CyclicDB.HEADER_SIZE
                inOldLap := false
                continue
            }

            records.Push({
                offset:     pos,
                deleted:    marker = CyclicDB.RECORD_DELETED,
                keyLength:  keyLength,
                dataLength: dataLength,
                crc:        crc,
                size:       recordSize
            })
            pos += recordSize
        }
        return {records: records, lapEndAt: lapEndAt, badOffset: 0}
    }

    ; True when no record of the older lap starts at pos.
    _IsLapEnd(file, pos, maxSize) {
        if pos + CyclicDB.RECORD_HEADER_SIZE > Min(maxSize, file.Length)
            return true
        file.Seek(pos)
        return file.ReadUShort() = CyclicDB.RECORD_LAP_END
    }

    ; Marks the end of the current lap. Where the marker does not fit, the
    ; lap ends at the end of the file anyway.
    _MarkLapEnd(file, pos) {
        if pos + 2 <= this.maxSize
            this._WriteUShortAt(file, pos, CyclicDB.RECORD_LAP_END)
    }

    ; Evicts the oldest record of the older lap and moves tail past it; once
    ; the older lap is used up, the ring is linear again. Returns
    ; {key, value: Buffer} for an evicted live record when collect=true.
    _AdvanceTail(collect := false) {
        file := this._file
        if !file || !this.wrapped
            return ''

        if this._IsLapEnd(file, this.tail, this.maxSize) {
            this._EndOlderLap()
            return ''
        }

        file.Seek(this.tail)
        marker     := file.ReadUShort()
        keyLength  := file.ReadUShort()
        dataLength := file.ReadUInt()
        recordSize := CyclicDB.RECORD_HEADER_SIZE + keyLength + dataLength

        if (marker != CyclicDB.RECORD_MARKER && marker != CyclicDB.RECORD_DELETED)
            || keyLength = 0 || this.tail + recordSize > Min(this.maxSize, file.Length) {
            ; A damaged header ends the older lap: nothing after it can be walked.
            this._EndOlderLap()
            return ''
        }

        evicted := ''
        if marker = CyclicDB.RECORD_MARKER {
            file.Seek(this.tail + CyclicDB.RECORD_HEADER_SIZE)
            keyBuf := Buffer(keyLength)
            file.RawRead(keyBuf)
            key := StrGet(keyBuf, 'UTF-8')
            if collect {
                dataBuf := Buffer(dataLength)
                if dataLength > 0
                    file.RawRead(dataBuf)
                evicted := {key: key, value: dataBuf}
            }
            if this.index.Has(key) && this.index[key].offset = this.tail
                this.index.Delete(key)
        }

        this.tail += recordSize
        if this._IsLapEnd(file, this.tail, this.maxSize)
            this._EndOlderLap()
        return evicted
    }

    ; The rest of the older lap is gone: the ring is linear from HEADER_SIZE
    ; to head. Index entries that still point into the dropped part go too.
    _EndOlderLap() {
        dropFrom := this.tail
        for key, entry in this.index.Clone() {
            if entry.offset >= dropFrom
                this.index.Delete(key)
        }
        this.tail    := CyclicDB.HEADER_SIZE
        this.wrapped := false
    }

    _PushEvicted(evicted, item) {
        if IsObject(item)
            evicted.Push(item)
    }

    _WriteRecordAt(file, pos, keyBuf, dataBuf, crc) {
        static header := Buffer(CyclicDB.RECORD_HEADER_SIZE)
        NumPut('UShort', CyclicDB.RECORD_MARKER, 'UShort', keyBuf.Size,
               'UInt',   dataBuf.Size,           'UInt',   crc, header)
        file.Seek(pos)
        this._WriteChecked(file, header)
        this._WriteChecked(file, keyBuf)
        this._WriteChecked(file, dataBuf)
    }

    _WriteUShortAt(file, pos, value) {
        static valueBuf := Buffer(2)
        NumPut('UShort', value, valueBuf)
        file.Seek(pos)
        this._WriteChecked(file, valueBuf)
    }

    ; File methods report a short write by their return value, not by throwing.
    _WriteChecked(file, buf) {
        if buf.Size > 0 && file.RawWrite(buf) != buf.Size
            throw Error('Failed to write the database file: ' . this.path)
    }

    ; True when the record at entry.offset is still the live record of key.
    _RecordMatches(file, entry, key) {
        try {
            if entry.offset + CyclicDB.RECORD_HEADER_SIZE + entry.keyLength > file.Length
                return false
            file.Seek(entry.offset)
            if file.ReadUShort() != CyclicDB.RECORD_MARKER
                || file.ReadUShort() != entry.keyLength
                || file.ReadUInt() != entry.dataLength
                return false
            keyBuf := Buffer(entry.keyLength)
            file.Seek(entry.offset + CyclicDB.RECORD_HEADER_SIZE)
            return file.RawRead(keyBuf) = entry.keyLength && StrGet(keyBuf, 'UTF-8') == key
        }
        return false
    }

    _ComputeCRC(keyBuf, dataBuf) {
        crc := DllCall('ntdll\RtlComputeCrc32', 'UInt',   0, 'Ptr',  keyBuf,  'UInt', keyBuf.Size,  'UInt')
        crc := DllCall('ntdll\RtlComputeCrc32', 'UInt', crc, 'Ptr', dataBuf,  'UInt', dataBuf.Size, 'UInt')
        return crc
    }

    _StringToUTF8(str) {
        size := StrPut(str, 'UTF-8')
        buf  := Buffer(size - 1)
        StrPut(str, buf, 'UTF-8')
        return buf
    }

    ; Convert an array of keys to a Map-as-set for O(1) lookup.
    _KeysToSet(keys) {
        set := Map()
        for k in keys
            set[k] := true
        return set
    }
}

class TranslationCache {
    static TYPE_TRANSLATION := 'T'
         , TYPE_AUDIO       := 'A'
         , DEFAULT_MAX_SIZE := 100 * 1024 * 1024  ; 100 MB

    db := ''
    lastTranslation := ''  ; {key, text, sl, tl, trans, variants}
    lastAudio := ''        ; {key, text, lang, data}

    ; Open or create cache
    Open(path, maxSize := '') {
        (maxSize == '' && maxSize := TranslationCache.DEFAULT_MAX_SIZE)
        this.db := CyclicDB()
        this.db.Open(path, maxSize)
        if this.db.maxSize != maxSize {
            this.db.Resize(maxSize)
        }
        return this
    }
    
    GetTranslation(text, sl, tl) {
        key := this._MakeTranslationKey(text, sl, tl)
        
        if this.lastTranslation && this.lastTranslation.key == key {
            return {trans: this.lastTranslation.trans, variants: this.lastTranslation.variants}
        }
        
        data := this.db.Get(key, &found := false)
        if !found {
            this._DeleteInvalidRecord(key)
            return ''
        }
        
        try {
            json := TextCompressor.Decompress(data)
        } catch {
            json := StrGet(data, 'UTF-8')
        }
        
        try {
            parsed := LightJson.Parse(json)
            
            this.lastTranslation := {
                key: key,
                text: text,
                sl: sl,
                tl: tl,
                trans: parsed['trans'],
                variants: parsed.Has('variants') ? parsed['variants'] : ''
            }
            
            return {trans: parsed['trans'], variants: this.lastTranslation.variants}
        } catch {
            this._DeleteInvalidRecord(key)
            return ''
        }
    }

    SetTranslation(text, sl, tl, trans, variants := '') {
        key := this._MakeTranslationKey(text, sl, tl)
        cacheEntry := {
            key: key,
            text: text,
            sl: sl,
            tl: tl,
            trans: trans,
            variants: variants
        }

        try {
            jsonObj := {trans: trans}
            (variants != '' && jsonObj.variants := variants)
            json := LightJson.Stringify(jsonObj)

            compressed := TextCompressor.Compress(json)
            if compressed {
                dataBuf := compressed
            } else {
                dataBuf := this._StringToUTF8(json)
            }
            this.db.Set(key, dataBuf)
        } catch {
            return false
        }

        this.lastTranslation := cacheEntry
        return true
    }
    
    GetAudio(text, lang) {
        key := this._MakeAudioKey(text, lang)
        
        if this.lastAudio && this.lastAudio.key == key {
            return this.lastAudio.data
        }
        
        data := this.db.Get(key, &found := false)
        if !found {
            this._DeleteInvalidRecord(key)
            return ''
        }
        if !(data is Buffer) || data.Size == 0 {
            this._DeleteInvalidRecord(key)
            return ''
        }
        
        this.lastAudio := {
            key: key,
            text: text,
            lang: lang,
            data: data
        }
        
        return data
    }

    SetAudio(text, lang, data) {
        if !(data is Buffer) || data.Size == 0 {
            return false
        }
        key := this._MakeAudioKey(text, lang)
        cacheEntry := {
            key: key,
            text: text,
            lang: lang,
            data: data
        }

        try this.db.Set(key, data)
        catch {
            return false
        }
        this.lastAudio := cacheEntry
        return true
    }
    
    HasTranslation(text, sl, tl) {
        key := this._MakeTranslationKey(text, sl, tl)
        if this.lastTranslation && this.lastTranslation.key == key {
            return true
        }
        return this.db.Has(key)
    }
    
    HasAudio(text, lang) {
        key := this._MakeAudioKey(text, lang)
        if this.lastAudio && this.lastAudio.key == key {
            return true
        }
        return this.db.Has(key)
    }
    
    GetStats() {
        translationBytes := 0
        audioBytes := 0
        translationCount := 0
        audioCount := 0

        for key, entry in this.db.index {
            recordSize := CyclicDB.RECORD_HEADER_SIZE + entry.keyLength + entry.dataLength
            entryType := SubStr(key, 1, 1)
            if entryType == TranslationCache.TYPE_TRANSLATION {
                translationBytes += recordSize
                translationCount++
            } else if entryType == TranslationCache.TYPE_AUDIO {
                audioBytes += recordSize
                audioCount++
            }
        }

        totalBytes := translationBytes + audioBytes
        capacityBytes := Max(0, this.db.maxSize - CyclicDB.HEADER_SIZE)
        return {
            recordCount: this.db.index.Count,
            translationCount: translationCount,
            audioCount: audioCount,
            translationBytes: translationBytes,
            audioBytes: audioBytes,
            totalBytes: totalBytes,
            maxSize: this.db.maxSize,
            usagePercent: capacityBytes ? Round(totalBytes / capacityBytes * 100, 2) : 0,
            audioRatio: totalBytes ? audioBytes / totalBytes : 0
        }
    }
    
    Resize(newMaxSize) {
        result := this.db.Resize(newMaxSize)
        return result.ok
    }
    
    Clear() {
        this.lastTranslation := ''
        this.lastAudio := ''
        this.db.Clear()
    }
    
    Close() {
        this.db.Close()
        this.lastTranslation := ''
        this.lastAudio := ''
    }

    _DeleteInvalidRecord(key) {
        if this.db.Has(key) {
            try this.db.Delete(key)
        }
        if this.lastTranslation && this.lastTranslation.key == key {
            this.lastTranslation := ''
        }
        if this.lastAudio && this.lastAudio.key == key {
            this.lastAudio := ''
        }
    }

    _MakeTranslationKey(text, sl, tl) {
        source := text . '|' . sl . '|' . tl
        return TranslationCache.TYPE_TRANSLATION . this._Hash(source)
    }

    _MakeAudioKey(text, lang) {
        source := text . '|' . lang
        return TranslationCache.TYPE_AUDIO . this._Hash(source)
    }

    _Hash(str) {
        buf := this._StringToUTF8(str)
        hashBuf := this._CreateSHA256(buf)
        return BinaryEncoder.CryptBinaryToString(hashBuf)
    }

    _CreateSHA256(dataBuf) {
        DllCall('Bcrypt\BCryptOpenAlgorithmProvider', 'Ptr*', &hAlgorithm := 0, 'WStr', 'SHA256', 'Ptr', 0, 'UInt', 0)
        DllCall('Bcrypt\BCryptCreateHash', 'Ptr', hAlgorithm, 'Ptr*', &hHash := 0
                                         , 'Ptr', 0, 'UInt', 0, 'Ptr', 0, 'UInt', 0, 'UInt', 0)
        DllCall('Bcrypt\BCryptHashData', 'Ptr', hHash, 'Ptr', dataBuf, 'UInt', dataBuf.Size, 'UInt', 0)
        DllCall('Bcrypt\BCryptGetProperty', 'Ptr', hAlgorithm, 'WStr', 'HashDigestLength'
                                          , 'UInt*', &hashLen := 0, 'UInt', 4, 'UIntP', &res := 0, 'UInt', 0)
        hashBuf := Buffer(hashLen, 0)
        DllCall('Bcrypt\BCryptFinishHash', 'Ptr', hHash, 'Ptr', hashBuf, 'UInt', hashLen, 'UInt', 0)
        DllCall('Bcrypt\BCryptDestroyHash', 'Ptr', hHash)
        DllCall('Bcrypt\BCryptCloseAlgorithmProvider', 'Ptr', hAlgorithm, 'UInt', 0)
        return hashBuf
    }

    _StringToUTF8(str) {
        size := StrPut(str, 'UTF-8') - 1
        buf := Buffer(size)
        StrPut(str, buf, 'UTF-8')
        return buf
    }
}

; Stands in for TranslationCache when the cache file cannot be opened.
class DisabledTranslationCache
{
    __New(reason := '') => this.reason := reason

    GetTranslation(*) => ''
    SetTranslation(*) => false
    GetAudio(*) => ''
    SetAudio(*) => false
    HasTranslation(*) => false
    HasAudio(*) => false
    Clear() => ''
    Close() => ''
}

class TextCompressor
{
    #DllLoad Cabinet.dll

    static MAGIC := 0x504D4354       ; 'TCMP' (LE)
         , VERSION := 1
         , CT_ALGO_XPRESS_HUFF := 1
         , WIN_ALGO_XPRESS_HUFF := 4 ; COMPRESS_ALGORITHM_XPRESS_HUFF
         , FLAG_ENC_UTF16LE := 0x01  ; 0 = UTF-8, 1 = UTF-16LE
         , CHUNKFLAG_RAW := 0x01
         , BLOCK_SIZE := 256 * 1024  ; 256 KiB

    static Compress(text) {
        if (text = '')
            return false

        len16 := StrLen(text) * 2
        need8 := StrPut(text, 'UTF-8') - 1
        useUtf8 := (need8 < len16)
        encFlag := useUtf8 ? 0 : this.FLAG_ENC_UTF16LE

        if (useUtf8) {
            uncTotal := need8
            inBuf := Buffer(uncTotal)
            StrPut(text, inBuf, 'UTF-8')
            pIn := inBuf.Ptr
        } else {
            uncTotal := len16
            pIn := StrPtr(text)
            inBuf := ''
        }
        if !DllCall('Cabinet\CreateCompressor', 'UInt', this.WIN_ALGO_XPRESS_HUFF, 'Ptr', 0, 'Ptr*', &hcmp := 0)
            throw Error('CreateCompressor failed. LastError=' . A_LastError)

        chunks := []
        crc := 0
        pos := 0
        bs := this.BLOCK_SIZE

        try {
            while (pos < uncTotal) {
                clen := uncTotal - pos
                if (clen > bs)
                    clen := bs
                pBlock := pIn + pos

                crc := DllCall('ntdll\RtlComputeCrc32', 'UInt', crc, 'Ptr', pBlock, 'UInt', clen, 'UInt')

                DllCall('Cabinet\Compress', 'Ptr', hcmp, 'Ptr', pBlock, 'Ptr', clen, 'Ptr', 0, 'Ptr', 0, 'Ptr*', &req := 0)
                (!req && req := clen + (clen >> 4) + 64)

                bufCmp := Buffer(req)
                ok := DllCall('Cabinet\Compress', 'Ptr', hcmp, 'Ptr', pBlock, 'Ptr', clen, 'Ptr', bufCmp, 'Ptr', req, 'Ptr*', &written := 0)
                if (!ok || written >= clen) {
                    payload := Buffer(clen)
                    DllCall('RtlMoveMemory', 'Ptr', payload, 'Ptr', pBlock, 'Ptr', clen)
                    chunks.Push({flags: this.CHUNKFLAG_RAW, unc: clen, cmp: clen, data: payload})
                } else {
                    if (written < req) {
                        trimmed := Buffer(written)
                        DllCall('RtlMoveMemory', 'Ptr', trimmed, 'Ptr', bufCmp, 'Ptr', written)
                        bufCmp := trimmed
                    }
                    chunks.Push({flags: 0, unc: clen, cmp: written, data: bufCmp})
                }
                pos += clen
            }
        } finally {
            DllCall('Cabinet\CloseCompressor', 'Ptr', hcmp)
        }
        hdrSize := 4 + 1 + 1 + 1 + 4 + 8 + 4 + 4
        blkOver := 1 + 4 + 4
        payload := 0
        for c in chunks
            payload += blkOver + c.cmp
        totalSize := hdrSize + payload

        if (totalSize >= len16)
            return false

        NumPut('UInt'  , this.MAGIC, 'UChar', this.VERSION,
               'UChar' , this.CT_ALGO_XPRESS_HUFF,
               'UChar' , encFlag   , 'UInt' , bs,
               'UInt64', uncTotal  , 'UInt' , chunks.Length,
               'UInt'  , crc       , out := Buffer(totalSize))

        off := hdrSize

        for c in chunks {
            NumPut('UChar', c.flags, 'UInt', c.unc, 'UInt', c.cmp, out, off)
            DllCall('RtlMoveMemory', 'Ptr', out.Ptr + off + blkOver, 'Ptr', c.data, 'Ptr', c.cmp)
            off += c.cmp + blkOver
        }
        if (off != totalSize)
            throw Error('Container size mismatch at finalize')

        return out
    }

    static Decompress(buf) {
        if !buf || !(buf is Buffer)
            throw Error('Decompress: argument must be a Buffer')

        sz := buf.Size
        if (sz < 27)
            throw Error('Decompress: buffer too small')

        off := 0
        magic := NumGet(buf, off, 'UInt'),  off += 4
        if (magic != this.MAGIC)
            throw Error('Decompress: bad magic')

        ver := NumGet(buf, off, 'UChar'),   off += 1
        if (ver != this.VERSION)
            throw Error('Decompress: unsupported version ' . ver)

        algoId := NumGet(buf, off, 'UChar'), off += 1
        if (algoId != this.CT_ALGO_XPRESS_HUFF)
            throw Error('Decompress: unsupported algo id ' . algoId)

        flags := NumGet(buf, off, 'UChar'), off += 1
        encUtf16 := (flags & this.FLAG_ENC_UTF16LE) != 0

        blockSize := NumGet(buf, off, 'UInt')  , off += 4
        uncTotal  := NumGet(buf, off, 'UInt64'), off += 8
        chunksN   := NumGet(buf, off, 'UInt')  , off += 4
        crcStored := NumGet(buf, off, 'UInt')  , off += 4

        if (chunksN = 0 && uncTotal != 0)
            throw Error('Decompress: invalid header (chunks=0 but data length>0)')
        ; The header comes from a file, so its sizes are checked before any
        ; buffer is allocated from them.
        if (blockSize = 0 || blockSize > 16 * 1024 * 1024)
            throw Error('Decompress: invalid block size ' . blockSize)
        if (chunksN > (sz - off) // 9)
            throw Error('Decompress: truncated chunk table')
        if (uncTotal > chunksN * blockSize)
            throw Error('Decompress: invalid header (data length exceeds the blocks)')
        if (uncTotal = 0)
            return ''

        if !DllCall('Cabinet\CreateDecompressor', 'UInt', this.WIN_ALGO_XPRESS_HUFF, 'Ptr', 0, 'Ptr*', &hdec := 0)
            throw Error('CreateDecompressor failed. LastError=' . A_LastError)

        out := Buffer(uncTotal)
        outPos := 0
        crc := 0

        try {
            loop chunksN {
                if (off + 1 + 4 + 4 > sz)
                    throw Error('Decompress: truncated chunk header')

                cFlags := NumGet(buf, off, 'UChar'), off += 1
                uncLen := NumGet(buf, off, 'UInt') , off += 4
                cmpLen := NumGet(buf, off, 'UInt') , off += 4

                if (cFlags & ~this.CHUNKFLAG_RAW)
                    throw Error('Decompress: unsupported chunk flags ' . cFlags)
                if (uncLen > blockSize)
                    throw Error('Decompress: chunk larger than the block size')
                ; A raw chunk is copied as is: both lengths must agree, or the
                ; copy would read past the payload.
                if ((cFlags & this.CHUNKFLAG_RAW) && cmpLen != uncLen)
                    throw Error('Decompress: raw chunk length mismatch')
                if (off + cmpLen > sz)
                    throw Error('Decompress: truncated chunk payload')

                if (outPos + uncLen > uncTotal)
                    throw Error('Decompress: uncompressed length overflow')

                pDst := out.Ptr + outPos

                if (cFlags & this.CHUNKFLAG_RAW) {
                    DllCall('RtlMoveMemory', 'Ptr', pDst, 'Ptr', buf.Ptr + off, 'Ptr', uncLen)
                } else {
                    ok := DllCall('Cabinet\Decompress', 'Ptr', hdec, 'Ptr', buf.Ptr + off, 'Ptr', cmpLen,
                                                        'Ptr', pDst, 'Ptr', uncLen, 'Ptr*', &written := 0)
                    if (!ok || written != uncLen)
                        throw Error('Decompress: block failed or size mismatch')
                }

                crc := DllCall('ntdll\RtlComputeCrc32', 'UInt', crc, 'Ptr', pDst, 'UInt', uncLen, 'UInt')

                outPos += uncLen
                off += cmpLen
            }
        } finally {
            DllCall('Cabinet\CloseDecompressor', 'Ptr', hdec)
        }

        if (outPos != uncTotal)
            throw Error('Decompress: total length mismatch')
        if (crc != crcStored)
            throw Error(Format('Decompress: CRC mismatch (got {:#x}, want {:#x})', crc, crcStored))

        return encUtf16 ? StrGet(out, uncTotal // 2) : StrGet(out, uncTotal, 'UTF-8')
    }
}

class AudioPlayer
{
    /**
     * Creates a new audio player instance
     * @param {String|ComValue|Ptr|Buffer} mediaSource  Media source, can be file path, URL, IStream or Buffer with audio file data
     * @param {String}                     sourceType   Type of media source: 'file', 'URL', 'Stream', or 'Buffer'
     * @param {String}                     fileType     Audio format (e.g., 'mp3', 'flac'). Leave empty to auto-detect
     * @param {Boolean}                    startNow     Start playback immediately after creation
     * @param {Func}                       shouldCancel Optional predicate polled while the source
     *                                                  is being resolved; true abandons the wait
     */

    __New(mediaSource, sourceType := '', fileType := '', startNow := true, shouldCancel := '') {
        if !sourceType {
            switch {
                case mediaSource is Buffer:
                    sourceType := 'Buffer'
                case Type(mediaSource) == 'String' && FileExist(mediaSource):
                    sourceType := 'file'
                case Type(mediaSource) == 'String' && mediaSource ~= 'i)^https?://':
                    sourceType := 'URL'
                default:
                    sourceType := 'Stream'
            }
        }
        if !(sourceType ~= 'i)^(file|URL|Stream|Buffer)$') {
            throw ValueError('Unsupported source type: ' . sourceType)
        }
        this.session := MediaSession(mediaSource, sourceType, fileType, shouldCancel)
        if !(this.session is MediaSession) {
            this.session := ''
        }
        (startNow && this.Start())
    }

    masterVolume {
        get => this.session ? Round(this.session.audio.GetVolume(), 2) : ''
        set { ; 0.0 - 1.0
            if !(value is Number && 0 <= value && value <= 1) {
                throw ValueError('Volume must be between 0.0 and 1.0')
            }
            (this.session && this.session.audio.SetVolume(value))
        }
    }
    state => this.session ? this.session.playback.GetState() : '' ; returns 'running', 'stopped', 'paused' or 'invalid'

    Start() => this.session && this.session.playback.Start()
    Pause() => this.session && this.session.playback.Pause()
    Stop()  => this.session && this.session.playback.Stop()

    ; 1.0 - playback speed 100%, 0.5 - 50%, -0.5 - speed 50% in reverse. This option does not always work.
    SetPlaybackRate(rate) => this.session && this.session.playback.rateControl.SetRate(rate)

    ; Uses the clock acquired once in PlaybackController instead of calling
    ; IMFMediaSession::GetClock several times per second.
    GetPosition() {
        if !this.session
            return 0
        return this.session.playback.clock.GetCorrelatedTime()
    }
}

class MediaSession
{
    #DllLoad Mfplat.dll
    #DllLoad Mf.dll

    ; MFSTARTUP_NOSOCKET (0x1) skips socket initialisation; MFSTARTUP_FULL is 0.
    ; Startup is deferred to the first MediaSession so a caller can change this
    ; before any session exists (a class static initialiser would run too early).
    static startupFlags := 0x1
    static started := false

    ; The Media Session creates a default quality manager, which is allowed to
    ; drop samples when it decides the pipeline is falling behind. Setting
    ; MF_SESSION_QUALITY_MANAGER to GUID_NULL runs the session without one.
    ; https://learn.microsoft.com/en-us/windows/win32/medfound/mf-session-quality-manager-attribute
    static disableQualityManager := false

    ; Audio session of the renderer (MF_AUDIO_RENDERER_ATTRIBUTE_SESSION_ID).
    ; Windows remembers the volume per executable and session GUID, so an own
    ; GUID keeps a program's volume apart from other scripts run by the same
    ; interpreter. Empty means the application's default session.
    static audioSessionId := ''
    ; Name and icon ("path,index") shown for that session in the volume mixer.
    static audioSessionName := ''
    static audioSessionIcon := ''

    ; A library must not open dialogs: a failed session inside a timer tick
    ; would block the script thread, and with it the local server feeding MF.
    ; The text is kept in `lastError` instead; set this to true for a quick
    ; standalone script.
    static showErrorDialog := false
    static lastError := ''

    static EnsureStartup() {
        if MediaSession.started
            return
        static MF_VERSION               := 0x2
             , MF_E_BAD_STARTUP_VERSION  := 0xC00D36E3
             , MF_E_DISABLED_IN_SAFEMODE := 0xC00D36EF
             , E_NOTIMPL                 := 0x80004001

        startupResult := DllCall('Mfplat\MFStartup', 'UInt', MF_VERSION,
                                                       'UInt', MediaSession.startupFlags, 'UInt')
        if startupResult != 0 {
            switch startupResult {
                case MF_E_BAD_STARTUP_VERSION:
                    errorMessage := 'The version of the Media Foundation platform is not supported.'
                case MF_E_DISABLED_IN_SAFEMODE:
                    errorMessage := 'Media Foundation is disabled in Safe Mode.'
                case E_NOTIMPL:
                    errorMessage := 'Media Foundation is not implemented on the system.'
                default:
                    errorMessage := 'MFStartup failed with HRESULT ' . Format('{:#x}', startupResult)
            }
            throw Error(errorMessage)
        }
        MediaSession.started := true
        OnExit((*) => DllCall('Mfplat\MFShutdown'))
    }

    ; Configuration attribute store for MFCreateMediaSession, or 0 for defaults
    static CreateConfiguration() {
        static MF_SESSION_QUALITY_MANAGER := '{1E83D482-1F1C-4571-8405-88F4B2181F73}'
        if !MediaSession.disableQualityManager
            return 0
        if DllCall('Mfplat\MFCreateAttributes', 'Ptr*', &pAttributes := 0, 'UInt', 1) != 0
            return 0
        attributes := ComValue(13, pAttributes)
        DllCall('Ole32\CLSIDFromString', 'Str', MF_SESSION_QUALITY_MANAGER, 'Ptr', key := Buffer(16))
        ComCall(SetGUID := 24, attributes, 'Ptr', key, 'Ptr', Buffer(16, 0))   ; GUID_NULL
        return attributes
    }

    ; Text left in lastError when the wait was abandoned rather than failed.
    static CANCELLED := 'the media session build was cancelled'

    ; Managers whose resolve was abandoned. MF still invokes their callback
    ; once the cancelled request finishes, and the thunk cannot be freed
    ; before that - Clear() would pull it out from under a call MF is about
    ; to make. They are reaped by the next session rather than by a timer:
    ; there is at most one per abandoned build, and building the next session
    ; is the only thing that follows one.
    static abandoned := []

    static Abandon(manager) => MediaSession.abandoned.Push(manager)

    static ReapAbandoned() {
        pending := []
        for manager in MediaSession.abandoned {
            ; Still false means Invoke has not run yet; -1 and true are both
            ; "MF is done with it".
            if !manager.initialized
                pending.Push(manager)
            else
                manager.Clear()
        }
        MediaSession.abandoned := pending
    }

    __New(mediaSource, sourceType := 'file', fileType := '', shouldCancel := '') {
        MediaSession.EnsureStartup()
        MediaSession.ReapAbandoned()
        this.cancelled := false
        this.session := IMFMediaSession.Create(MediaSession.CreateConfiguration())
        this.sourceManager := MediaSourceManager(mediaSource, sourceType, fileType)
        try {
            built := this.InitializeComponents(shouldCancel)
        } catch Error as buildError {
            ; __Delete still shuts the session down: the base is unchanged.
            this.ReleaseSourceManager()
            throw buildError
        }
        if !built {
            ; A failed session loses its base, and with it __Delete, so it is
            ; shut down here: MF requires Shutdown before the last Release.
            this.ShutdownSession()
            if this.cancelled {
                MediaSession.lastError := MediaSession.CANCELLED
                this.ReleaseSourceManager()
                ObjSetBase(this, {})
                return
            }
            this.ReportError(sourceType, fileType)
            ObjSetBase(this, {})
        }
        this.ReleaseSourceManager()
    }

    ; On a clean exit the OnExit handler may have called MFShutdown already,
    ; in which case Shutdown() returns MF_E_SHUTDOWN (0xC00D3E85). Harmless.
    __Delete() => this.ShutdownSession()

    ShutdownSession() {
        try this.session.Shutdown()
    }

    ; Frees the source manager's callback once MF is done with it. A resolve
    ; still in flight (a cancelled build) leaves it to ReapAbandoned.
    ReleaseSourceManager() {
        manager := this.sourceManager
        this.sourceManager := ''
        if !manager
            return
        if manager.initialized {
            manager.Clear()
        } else {
            manager.Cancel()
            MediaSession.Abandon(manager)
        }
    }

    /**
     * Waits for the async source resolver, then builds the topology.
     *
     * This wait is the one place the pipeline blocks its caller for an
     * unbounded time: MF gives no deadline of its own, and a stream it cannot
     * sniff has been measured sitting here for 34 seconds - that was
     * icecast.radiofrance.fr AAC, back when the relay still served it as
     * audio/mpeg, and any stream whose framing MF does not recognise does
     * the same. Whoever owns the thread usually has work
     * queued behind that - a Stop the user pressed, a different station - and
     * `shouldCancel` is how it says so. Abandoning the wait is safe: nothing
     * has been half torn down, the session simply never gets built, and the
     * caller is told the same way a failure is told.
     */
    InitializeComponents(shouldCancel := '') {
        Loop {
            Sleep 10
            if this.sourceManager.initialized == -1
                return false
            if (shouldCancel && shouldCancel.Call()) {
                this.cancelled := true
                this.sourceManager.Cancel()
                return false
            }
        } until this.sourceManager.initialized
        topBuilder := TopologyBuilder(this.sourceManager.MediaSource,
                                      this.sourceManager.PresentationDescriptor)
        this.session.SetTopology(0, topBuilder.topology)
        this.playback := PlaybackController(this.session)
        this.audio := AudioController(this.session)
        this.ApplyAudioPolicy()
        return true
    }

    ; Best effort: a session without a name or icon plays all the same.
    ApplyAudioPolicy() {
        if MediaSession.audioSessionName == '' && MediaSession.audioSessionIcon == '' {
            return
        }
        try {
            audioPolicy := this.session.GetAudioPolicy()
            if MediaSession.audioSessionName != '' {
                audioPolicy.SetDisplayName(MediaSession.audioSessionName)
            }
            if MediaSession.audioSessionIcon != '' {
                audioPolicy.SetIconPath(MediaSession.audioSessionIcon)
            }
        }
    }

    ReportError(sourceType, fileType) {
        if !this.sourceManager.HasOwnProp('error')
            return
        switch {
            case this.sourceManager.error ~= 'i)\(0xC00D36C4\)'
                 && sourceType != 'URL' && fileType == '':
                errorMessage := '(0xC00D36C4) The byte stream type is not supported. Try to explicitly specify the correct fileType.'
            case sourceType == 'URL' && this.sourceManager.error ~= 'i)0xC00D2EE3':
                errorMessage := 'NS_E_BAD_REQUEST (0xC00D2EE3) The request could not be understood by the server.'
            default:
                errorMessage := this.sourceManager.error
        }
        MediaSession.lastError := errorMessage
        if MediaSession.showErrorDialog
            MsgBox errorMessage, 'Error', 16
    }
}

class MediaSourceManager
{
    __New(mediaSource, sourceType, fileType) {
        this.initialized := false
        this.cancelCookie := 0
        this.sourceType := sourceType
        this.fileType := fileType
        this.InitializeSource(mediaSource)
    }

    InitializeSource(mediaSource) {
        this.SourceResolver := IMFSourceResolver.Create()
        switch this.sourceType, false {
            case 'URL'     : this.InitializeFromUrl(mediaSource)
            case 'file'    : this.InitializeFromFile(mediaSource)
            case 'Buffer'  : this.InitializeFromBuffer(mediaSource)
            case 'Stream'  : this.InitializeFromStream(mediaSource)
        }
    }

    InitializeFromFile(filePath) {
        static STGM_READ := 0, VT_UNKNOWN := 13
        if this.fileType == '' {
            SplitPath filePath,,, &ext
            (ext && this.fileType := ext)
        }
        DllCall('Shlwapi\SHCreateStreamOnFile', 'Str', filePath, 'UInt', STGM_READ,
                                                'Ptr*', IStream := ComValue(VT_UNKNOWN, 0))
        this.InitializeFromStream(IStream)
    }

    InitializeFromBuffer(buf) {
        pIStream := DllCall('Shlwapi\SHCreateMemStream', 'Ptr', buf, 'UInt', buf.size, 'Ptr')
        this.InitializeFromStream(ComValue(VT_UNKNOWN := 13, pIStream))
    }

    InitializeFromUrl(url) {
        static flag := MF_RESOLUTION_MEDIASOURCE := 1
        this.callback := IMFAsyncCallback(ObjBindMethod(this, 'OnAsyncComplete'))
        this.SourceResolver.BeginCreateObjectFromURL(url, flag, 0, &pIUnknownCancelCookie, this.callback)
        ; Kept, not released on the spot: it is the only handle on a resolve
        ; that may have to be called off - see Cancel(). Clear() releases it.
        this.cancelCookie := pIUnknownCancelCookie
    }

    InitializeFromStream(IStream) {
        static flag := MF_RESOLUTION_MEDIASOURCE := 1
        fileType := this.fileType ? 'file.' . this.fileType : ''
        this.ByteStream := IMFByteStream.CreateFromStream(IStream)
        this.callback := IMFAsyncCallback(ObjBindMethod(this, 'OnAsyncComplete'))
        this.SourceResolver.BeginCreateObjectFromByteStream(this.ByteStream, fileType, flag, 0,
                                                            &pIUnknownCancelCookie, this.callback)
        this.cancelCookie := pIUnknownCancelCookie
    }

    /**
     * Calls off a resolve that is still running. MF invokes the callback
     * anyway, with MF_E_CANCELED, so `initialized` still moves off false and
     * the thunk becomes safe to free - that is what MediaSession.ReapAbandoned
     * waits for. Best effort: a resolve that has just completed cannot be
     * cancelled any more, and that is not an error.
     */
    Cancel() {
        if (this.cancelCookie && this.SourceResolver)
            try this.SourceResolver.CancelObjectCreation(this.cancelCookie)
    }

    OnAsyncComplete(pAsyncResult) {
        method := 'EndCreateObjectFrom' . (this.sourceType = 'URL' ? 'URL' : 'ByteStream')
        ; Any failure has to move `initialized` off false: InitializeComponents
        ; waits for that, with no deadline of its own.
        try {
            this.MediaSource := this.SourceResolver.%method%(pAsyncResult, &MF_OBJECT_TYPE)
            this.PresentationDescriptor := this.MediaSource.CreatePresentationDescriptor()
        } catch Error as e {
            this.error := e.Message
            this.initialized := -1
            return
        }
        ; The callback is not freed here - this runs inside its own Invoke.
        ; Clear() does it once the caller is done.
        this.ByteStream := this.SourceResolver := ''
        this.initialized := true
    }

    /**
     * Called once the session has been built from the resolved source. Frees
     * the async callback too: by now Invoke has returned and MF has released
     * it (measured - see IMFAsyncCallback.Dispose). Each thunk holds an
     * AddRef'd closure bound to this object, so leaving them in place would
     * keep one MediaSourceManager alive per session forever.
     */
    Clear() {
        this.MediaSource := this.PresentationDescriptor := ''
        if this.cancelCookie {
            ObjRelease(this.cancelCookie)
            this.cancelCookie := 0
        }
        if (this.HasOwnProp('callback') && this.callback) {
            this.callback.Dispose()
            this.callback := ''
        }
    }
}

class TopologyBuilder
{
    __New(mediaSource, presentationDesc) {
        this.topology := IMFTopology.Create()
        Loop presentationDesc.GetStreamDescriptorCount() {
            this.AddBranchToPartialTopology(A_Index - 1, mediaSource, presentationDesc)
        }
    }

    AddBranchToPartialTopology(idx, mediaSource, presentationDesc) {
        static MFMediaType_Audio := '{73647561-0000-0010-8000-00AA00389B71}'
        StreamDescriptor := presentationDesc.GetStreamDescriptorByIndex(idx, &selected)
        if selected {
            MediaTypeHandler := StreamDescriptor.GetMediaTypeHandler()
            MediaTypeHandler.GetMajorType(GUID := Buffer(16))
            VarSetStrCapacity(&sGUID, 78)
            DllCall('Ole32\StringFromGUID2', 'Ptr', GUID, 'Str', sGUID, 'UInt', 39)
            if sGUID = MFMediaType_Audio {
                SourceTopologyNode := this.AddSourceNode(StreamDescriptor, mediaSource, presentationDesc)
                OutputTopologyNode := this.AddOutputNode()
                SourceTopologyNode.ConnectOutput(0, OutputTopologyNode, 0)
            }
        }
    }

    AddSourceNode(StreamDescriptor, mediaSource, presentationDesc) {
        static MF_TOPOLOGY_SOURCESTREAM_NODE := 1
             , MF_TOPONODE_SOURCE                  := '{835C58EC-E075-4BC7-BCBA-4DE000DF9AE6}'
             , MF_TOPONODE_PRESENTATION_DESCRIPTOR := '{835C58ED-E075-4BC7-BCBA-4DE000DF9AE6}'
             , MF_TOPONODE_STREAM_DESCRIPTOR       := '{835C58EE-E075-4BC7-BCBA-4DE000DF9AE6}'

        SourceTopologyNode := IMFTopologyNode.Create(MF_TOPOLOGY_SOURCESTREAM_NODE)
        SourceTopologyNode.SetUnknown(MF_TOPONODE_SOURCE, mediaSource)
        SourceTopologyNode.SetUnknown(MF_TOPONODE_PRESENTATION_DESCRIPTOR, presentationDesc)
        SourceTopologyNode.SetUnknown(MF_TOPONODE_STREAM_DESCRIPTOR, StreamDescriptor)
        this.Topology.AddNode(SourceTopologyNode.ptr)
        return SourceTopologyNode
    }

    AddOutputNode() {
        static MF_TOPOLOGY_OUTPUT_NODE := 0
             , MF_TOPONODE_STREAMID             := '{14932F9B-9087-4BB4-8412-5167145CBE04}'
             , MF_TOPONODE_NOSHUTDOWN_ON_REMOVE := '{14932F9C-9087-4BB4-8412-5167145CBE04}'

        static MF_AUDIO_RENDERER_ATTRIBUTE_SESSION_ID := '{EDE4B5E3-F805-4D6C-99B3-DB01BF95DFAB}'

        OutputTopologyNode := IMFTopologyNode.Create(MF_TOPOLOGY_OUTPUT_NODE)
        rendererActivate := IMFActivate.Create()
        ; Must be set before the renderer is activated, i.e. before SetTopology.
        if MediaSession.audioSessionId != '' {
            rendererActivate.SetGUID(MF_AUDIO_RENDERER_ATTRIBUTE_SESSION_ID, MediaSession.audioSessionId)
        }
        OutputTopologyNode.SetObject(rendererActivate)
        OutputTopologyNode.SetUINT32(MF_TOPONODE_STREAMID, 0)
        OutputTopologyNode.SetUINT32(MF_TOPONODE_NOSHUTDOWN_ON_REMOVE, 0)
        this.Topology.AddNode(OutputTopologyNode)
        return OutputTopologyNode
    }
}

class AudioController
{
    __New(session) => this.AudioVolume := session.GetSimpleAudioVolume()

    SetVolume(volume) => this.AudioVolume.SetMasterVolume(volume) ; 0.0 - 1.0

    GetVolume() => this.AudioVolume.GetMasterVolume()
}

class PlaybackController
{
    __New(session) {
        this.session := session
        this.clock := session.GetClock()
        this.rateControl := session.GetRateControl()
    }

    GetState() {
        static states := Map(
            MFCLOCK_STATE_INVALID := 0, 'invalid',
            MFCLOCK_STATE_RUNNING := 1, 'running',
            MFCLOCK_STATE_STOPPED := 2, 'stopped',
            MFCLOCK_STATE_PAUSED  := 3, 'paused'
        )
        return states[this.clock.GetState()]
    }

    Start(atBeginning := true) {
        GUID_NULL := Buffer(16, 0)
        PROPVARIANT := Buffer(8 + A_PtrSize * 2, 0)
        if atBeginning {
            NumPut('UShort', VT_I8 := 0x14, PROPVARIANT)
        }
        this.session.Start(GUID_NULL, PROPVARIANT)
    }

    Stop() => this.session.Stop()

    Pause() => this.GetState() == 'running' ? this.session.Pause() : this.Start(false)
}

class InterfaceBase {
    __New(obj) {
        this.ptr := obj is ComValue ? obj.ptr : obj
        this.obj := obj is ComValue ? obj : ComValue(VT_UNKNOWN := 13, obj)
    }
}

class IMFMediaSession extends InterfaceBase {
    static Create(pConfiguration := 0) {
        DllCall('Mf\MFCreateMediaSession', 'Ptr', pConfiguration, 'Ptr*', &pIMFMediaSession := 0)
        return IMFMediaSession(pIMFMediaSession)
    }
    static IIDFromString(iid) => (DllCall('Ole32\IIDFromString', 'Str', iid, 'Ptr', riid := Buffer(16)), riid)

    GetSimpleAudioVolume() {
        static MR_POLICY_VOLUME_SERVICE := '{1ABAA2AC-9D3B-47C6-AB48-C59506DE784D}'
             , IID_IMFSimpleAudioVolume := '{089EDF13-CF71-4338-8D13-9E569DBDC319}'
             , riid1 := IMFMediaSession.IIDFromString(MR_POLICY_VOLUME_SERVICE)
             , riid2 := IMFMediaSession.IIDFromString(IID_IMFSimpleAudioVolume)

        while DllCall('Mf\MFGetService', 'Ptr', this, 'Ptr', riid1, 'Ptr', riid2,
                                                      'Ptr*', &pIMFSimpleAudioVolume := 0) != 0 {
            if A_Index > 50 {
                throw Error('Failed to get audio volume service')
            }
            Sleep 10
        }
        return IMFSimpleAudioVolume(pIMFSimpleAudioVolume)
    }
    GetAudioPolicy() {
        static MR_AUDIO_POLICY_SERVICE := '{911FD737-6775-4AB0-A614-297862FDAC88}'
             , IID_IMFAudioPolicy      := '{A0638C2B-6465-4395-9AE7-A321A9FD2856}'
             , riid1 := IMFMediaSession.IIDFromString(MR_AUDIO_POLICY_SERVICE)
             , riid2 := IMFMediaSession.IIDFromString(IID_IMFAudioPolicy)

        if DllCall('Mf\MFGetService', 'Ptr', this, 'Ptr', riid1, 'Ptr', riid2,
                                      'Ptr*', &pIMFAudioPolicy := 0) != 0 {
            throw Error('The audio policy service is unavailable')
        }
        return IMFAudioPolicy(pIMFAudioPolicy)
    }
    GetRateControl() {
        static MF_RATE_CONTROL_SERVICE := '{866FA297-B802-4BF8-9DC9-5E3B6A9F53C9}'
             , IID_IMFRateControl      := '{88DDCD21-03C3-4275-91ED-55EE3929328F}'
             , riid1 := IMFMediaSession.IIDFromString(MF_RATE_CONTROL_SERVICE)
             , riid2 := IMFMediaSession.IIDFromString(IID_IMFRateControl)

        DllCall('Mf\MFGetService', 'Ptr', this, 'Ptr', riid1, 'Ptr', riid2, 'Ptr*', &pIMFRateControl := 0)
        return IMFRateControl(pIMFRateControl)
    }
    SetTopology(flags, IMFTopology) =>  ComCall( 7, this, 'UInt', flags, 'Ptr', IMFTopology)
    Start(pGUID, pVariant)          =>  ComCall( 9, this, 'Ptr', pGUID, 'Ptr', pVariant)
    Pause()                         =>  ComCall(10, this)
    Stop()                          =>  ComCall(11, this)
    Shutdown()                      =>  ComCall(13, this)
    GetClock()                      => (ComCall(14, this, 'Ptr*', &pIMFClock := 0), IMFClock(pIMFClock))
}

class IMFClock extends InterfaceBase {
    ; Both calls fail with MF_E_NO_CLOCK (0xC00D9C41) between creating a session
    ; and its presentation clock getting a time source - a window of a few
    ; hundred milliseconds that any poller will hit sooner or later. ComCall
    ; raises on a failed HRESULT rather than returning it, so the answer is to
    ; catch and report "no clock yet": state invalid, position zero.
    GetState() {
        state := 0      ; MFCLOCK_STATE_INVALID
        try ComCall(6, this, 'UInt', 0, 'UInt*', &state)
        return state
    }

    ; Returns the current presentation time in seconds
    GetCorrelatedTime() {
        clockTime := 0
        try ComCall(4, this, 'UInt', 0, 'Int64*', &clockTime, 'Int64*', &systemTime := 0)
        catch
            return 0
        return clockTime / 10000000.0   ; 100-nanosecond units
    }
}

class IMFSourceResolver extends InterfaceBase {
    IID_IMFMediaSource := '{279A808D-AEC7-40C8-9C6B-A6B492C78A66}'
    static Create() {
        DllCall('Mfplat\MFCreateSourceResolver', 'Ptr*', &pIMFSourceResolver := 0)
        return IMFSourceResolver(pIMFSourceResolver)
    }
    BeginCreateObjectFromURL(url, flags, pIPropertyStore, &pIUnknownCancelCookie, pCallback, punkState := 0) {
        ComCall(5, this, 'Str', url, 'UInt', flags, 'Ptr', pIPropertyStore,
                         'Ptr*', &pIUnknownCancelCookie := 0, 'Ptr', pCallback, 'Ptr', punkState)
    }
    EndCreateObjectFromURL(pIMFAsyncResult, &MF_OBJECT_TYPE) {
        ComCall(6, this, 'Ptr', pIMFAsyncResult, 'UInt*', &MF_OBJECT_TYPE := 0, 'Ptr*', &pIUnknown := 0)
        MediaSource := ComObjQuery(pIUnknown, this.IID_IMFMediaSource)
        ObjRelease(pIUnknown)
        return IMFMediaSource(MediaSource)
    }
    BeginCreateObjectFromByteStream(pIMFByteStream, url, flags, pProps, &ppIUnknownCancelCookie, pCallback, punkState := 0) {
        ComCall(7, this, 'Ptr', pIMFByteStream, 'Str', url, 'UInt', flags, 'Ptr', pProps,
                         'Ptr*', &ppIUnknownCancelCookie := 0, 'Ptr', pCallback, 'Ptr', punkState)
    }
    CancelObjectCreation(pIUnknownCancelCookie) {
        ComCall(9, this, 'Ptr', pIUnknownCancelCookie)
    }
    EndCreateObjectFromByteStream(pIMFAsyncResult, &MF_OBJECT_TYPE) {
        ComCall(8, this, 'Ptr', pIMFAsyncResult, 'UInt*', &MF_OBJECT_TYPE := 0, 'Ptr*', &pIUnknown := 0)
        MediaSource := ComObjQuery(pIUnknown, this.IID_IMFMediaSource)
        ObjRelease(pIUnknown)
        return IMFMediaSource(MediaSource)
    }
}

class IMFByteStream extends InterfaceBase {
    static CreateFromStream(pIStream) {
       hr := DllCall('Mfplat\MFCreateMFByteStreamOnStream', 'Ptr', pIStream, 'Ptr*', &pIMFByteStream := 0)
       return IMFByteStream(pIMFByteStream)
    }
}

class IMFMediaSource extends InterfaceBase {
    CreatePresentationDescriptor() {
        ComCall(8, this, 'Ptr*', &pIMFPresentationDescriptor := 0)
        return IMFPresentationDescriptor(pIMFPresentationDescriptor)
    }
}

class IMFPresentationDescriptor extends InterfaceBase {
    GetStreamDescriptorCount() {
        ComCall(33, this, 'UInt*', &descriptorCount := 0)
        return descriptorCount
    }
    GetStreamDescriptorByIndex(idx, &selected) {
        ComCall(34, this, 'UInt', idx, 'UInt*', &selected := 0, 'Ptr*', &pIMFStreamDescriptor := 0)
        return IMFStreamDescriptor(pIMFStreamDescriptor)
    }
}

class IMFStreamDescriptor extends InterfaceBase {
    GetMediaTypeHandler() {
        ComCall(34, this, 'Ptr*', &pIMFMediaTypeHandler := 0)
        return IMFMediaTypeHandler(pIMFMediaTypeHandler)
    }
}

class IMFMediaTypeHandler extends InterfaceBase {
    GetMajorType(GUID) => ComCall(8, this, 'Ptr', GUID)
}

class IMFTopology extends InterfaceBase {
    static Create() {
        DllCall('Mf\MFCreateTopology', 'Ptr*', &pIMFTopology := 0)
        return IMFTopology(pIMFTopology)
    }
    AddNode(pNode) => ComCall(34, this, 'Ptr', pNode)
}

class IMFTopologyNode extends InterfaceBase {
    static Create(type) {
        DllCall('Mf\MFCreateTopologyNode', 'UInt', type, 'Ptr*', &pIMFTopologyNode := 0)
        return IMFTopologyNode(pIMFTopologyNode)
    }
    SetUINT32(GUID, value) {
        DllCall('Ole32\CLSIDFromString', 'Str', GUID, 'Ptr', CLSID := Buffer(16))
        ComCall(21, this, 'Ptr', CLSID, 'UInt', value)
    }
    SetUnknown(GUID, pi) {
        DllCall('Ole32\CLSIDFromString', 'Str', GUID, 'Ptr', CLSID := Buffer(16))
        ComCall(27, this, 'Ptr', CLSID, 'Ptr', pi)
    }
    SetObject(pi) => ComCall(33, this, 'Ptr', pi)
    ConnectOutput(outputIndex, pDownstreamNode, dwInputIndexOnDownstreamNode) {
        ComCall(40, this, 'UInt', outputIndex, 'Ptr', pDownstreamNode, 'UInt', dwInputIndexOnDownstreamNode)
    }
}

class IMFActivate extends InterfaceBase {
    static Create() {
        DllCall('Mf\MFCreateAudioRendererActivate', 'Ptr*', &pIMFActivate := 0)
        return IMFActivate(pIMFActivate)
    }
    ; IMFAttributes::SetGUID
    SetGUID(attributeKey, guidValue) {
        DllCall('Ole32\CLSIDFromString', 'Str', attributeKey, 'Ptr', keyBuffer := Buffer(16))
        DllCall('Ole32\CLSIDFromString', 'Str', guidValue, 'Ptr', valueBuffer := Buffer(16))
        ComCall(24, this, 'Ptr', keyBuffer, 'Ptr', valueBuffer)
    }
}

class IMFAudioPolicy extends InterfaceBase {
    SetDisplayName(displayName) => ComCall(5, this, 'WStr', displayName)
    GetDisplayName() {
        ComCall(6, this, 'Ptr*', &textPtr := 0)
        displayName := StrGet(textPtr, 'UTF-16')
        DllCall('Ole32\CoTaskMemFree', 'Ptr', textPtr)
        return displayName
    }
    SetIconPath(iconPath) => ComCall(7, this, 'WStr', iconPath)
}

class IMFRateControl extends InterfaceBase {
    SetRate(rate, fThin := true) => ComCall(3, this, 'UInt', fThin, 'Float', rate)
}

class IMFSimpleAudioVolume extends InterfaceBase {
    SetMasterVolume(volume) => ComCall(3, this, 'Float', volume)
    GetMasterVolume() => (ComCall(4, this, 'Float*', &volume := 0), volume)
}

class IMFAsyncCallback {
    __New(userfunc) {
        this.thunks := []
        this.vtable := this.CreateVTable(userfunc)
        this.ptr := this.vtable.ptr
    }
    /**
     * Only Invoke runs script code, marshalled to the script thread. The
     * other four methods return constants, so they are native stubs shared
     * by all callbacks and never freed: MF calls Release after Invoke has
     * returned, possibly after Dispose has run, and a stub that outlives
     * every callback cannot be pulled out from under that call.
     */
    CreateVTable(userfunc) {
        stubs := IMFAsyncCallback.NativeStubs
        ; don't use CallbackCreate() here instead of RegisterSyncCallback()
        pInvoke := RegisterSyncCallback((self, pAsyncResult) => userfunc.Call(pAsyncResult))
        this.thunks.Push(pInvoke)
        vtable := Buffer(A_PtrSize * 6)
        NumPut('Ptr', vtable.ptr + A_PtrSize,
               'Ptr', stubs.queryInterface, 'Ptr', stubs.addRef, 'Ptr', stubs.release,
               'Ptr', stubs.getParameters,  'Ptr', pInvoke, vtable)
        return vtable
    }

    ; QueryInterface clears *ppv and returns E_NOINTERFACE, AddRef and Release
    ; return 1, GetParameters returns E_NOTIMPL. Built once per process.
    static NativeStubs {
        get {
            static stubs := ''
            if stubs
                return stubs
            if A_PtrSize = 8 {
                code := Map(
                    'queryInterface', [0x49, 0xC7, 0x00, 0, 0, 0, 0,       ; mov qword [r8], 0
                                       0xB8, 0x02, 0x40, 0x00, 0x80, 0xC3], ; mov eax, E_NOINTERFACE / ret
                    'addRef',         [0xB8, 0x01, 0, 0, 0, 0xC3],          ; mov eax, 1 / ret
                    'release',        [0xB8, 0x01, 0, 0, 0, 0xC3],
                    'getParameters',  [0xB8, 0x01, 0x40, 0x00, 0x80, 0xC3]  ; mov eax, E_NOTIMPL / ret
                )
            } else {
                code := Map(
                    'queryInterface', [0x8B, 0x44, 0x24, 0x0C,              ; mov eax, [esp+12]
                                       0xC7, 0x00, 0, 0, 0, 0,              ; mov dword [eax], 0
                                       0xB8, 0x02, 0x40, 0x00, 0x80,        ; mov eax, E_NOINTERFACE
                                       0xC2, 0x0C, 0x00],                   ; ret 12
                    'addRef',         [0xB8, 0x01, 0, 0, 0, 0xC2, 0x04, 0x00],
                    'release',        [0xB8, 0x01, 0, 0, 0, 0xC2, 0x04, 0x00],
                    'getParameters',  [0xB8, 0x01, 0x40, 0x00, 0x80, 0xC2, 0x0C, 0x00]
                )
            }
            static MEM_COMMIT_RESERVE := 0x3000, PAGE_READWRITE := 0x04, PAGE_EXECUTE_READ := 0x20
            memory := DllCall('VirtualAlloc', 'Ptr', 0, 'Ptr', 128, 'UInt', MEM_COMMIT_RESERVE,
                                              'UInt', PAGE_READWRITE, 'Ptr')
            if !memory
                throw OSError(A_LastError, -1, 'VirtualAlloc failed')
            result := {}
            offset := 0
            for name, bytes in code {
                result.%name% := memory + offset
                for byteValue in bytes
                    NumPut('UChar', byteValue, memory + offset++)
                offset := (offset + 15) & ~15
            }
            DllCall('VirtualProtect', 'Ptr', memory, 'Ptr', 128, 'UInt', PAGE_EXECUTE_READ, 'UInt*', 0)
            DllCall('FlushInstructionCache', 'Ptr', DllCall('GetCurrentProcess', 'Ptr'),
                                             'Ptr', memory, 'Ptr', 128)
            return stubs := result
        }
    }

    /**
     * Frees the Invoke thunk and the closure it holds. Call only once the
     * async operation is over: MF AddRefs the callback when the Begin call is
     * made and Releases it after Invoke returns, and nothing touches it
     * afterwards - measured in tests\AsyncCallbackTest.ahk (AddRef 1,
     * Release 1, and no further calls while the source is built and used).
     * AddRef and Release are native stubs that are never freed.
     *
     * The thunk holds an AddRef'd reference to its closure, so without this
     * the closure - and whatever it was bound to - lives until the process
     * ends.
     */
    Dispose() {
        for pcb in this.thunks
            FreeSyncCallback(pcb)
        this.thunks := []
        this.vtable := ''
        this.ptr := 0
    }
}

class SyncCallbackRegistry {
    static entries := Map()
}

FreeSyncCallback(pcb) {
    if !SyncCallbackRegistry.entries.Has(pcb)
        return false
    tail := SyncCallbackRegistry.entries.Delete(pcb)
    ObjRelease(NumGet(tail, 'Ptr'))          ; undo ObjPtrAddRef
    DllCall('GlobalFree', 'Ptr', pcb)
    return true
}

RegisterSyncCallback(funcObj, options := '', paramCount?) {
    static wnd := '', msg := 0x8000, SendMessageW := 0

    (!IsSet(paramCount) && paramCount := funcObj.MinParams)
    if IsSet(paramCount) && paramCount > funcObj.MaxParams {
        throw ValueError('Incorrect paramCount', paramCount)
    }
    if !wnd {
        wnd := Gui('+Parent' . A_ScriptHwnd)
        OnMessage(msg, RegisterSyncCallback_Msg)
        hModule := DllCall('GetModuleHandle', 'Str', 'user32.dll', 'Ptr')
        SendMessageW := DllCall('GetProcAddress', 'Ptr', hModule, 'AStr', 'SendMessageW', 'Ptr')
    }
    pcb := DllCall('GlobalAlloc', 'UInt', 0, 'Ptr', 96, 'Ptr')
    DllCall('VirtualProtect', 'Ptr', pcb, 'Ptr', 96, 'UInt', 0x40, 'UInt*', 0)

    p := pcb
    if A_PtrSize = 8 {
        /*
        48 89 4c 24 08  ; mov [rsp+8], rcx
        48 89 54'24 10  ; mov [rsp+16], rdx
        4c 89 44 24 18  ; mov [rsp+24], r8
        4c'89 4c 24 20  ; mov [rsp+32], r9
        48 83 ec 28'    ; sub rsp, 40
        4c 8d 44 24 30  ; lea r8, [rsp+48]  (arg 3, &params)
        49 b9 ..        ; mov r9, .. (arg 4, operand to follow)
        */
        p := NumPut('Ptr'  , 0x54894808244c8948,
                    'Ptr'  , 0x4c182444894c1024,
                    'Ptr'  , 0x28ec834820244c89,
                    'Ptr'  , 0x00b9493024448d4c, p) - 1
        lParamPtr := p, p += 8

        p := NumPut('Char' , 0xba,        ; mov edx, nmsg
                    'Int'  , msg,
                    'Char' , 0xb9,        ; mov ecx, hwnd
                    'Int'  , wnd.hwnd,
                    'Short', 0xb848,      ; mov rax, SendMessageW
                    'Ptr'  , SendMessageW,
                            /*
                            ff d0         ; call rax
                            48 83 c4 28   ; add rsp, 40
                            c3            ; ret
                            */
                    'Ptr'  , 0x00c328c48348d0ff, p)
    } else {
        p := NumPut('Char' , 0x68, p)     ; push ... (lParam data)
        lParamPtr := p, p += 4
        p := NumPut('Int'  , 0x0824448d,  ; lea eax, [esp+8]
                    'Char' , 0x50,        ; push eax
                    'Char' , 0x68,        ; push nmsg
                    'Int'  , msg,
                    'Char' , 0x68,        ; push hwnd
                    'Int'  , wnd.hwnd,
                    'Char' , 0xb8,        ; mov eax, &SendMessageW
                    'Int'  , SendMessageW,
                    'Short', 0xd0ff,      ; call eax
                    'Char' , 0xc2,        ; ret argsize
                    'Short', InStr(options, 'C') ? 0 : paramCount * 4, p)
    }
    NumPut('Ptr', p, lParamPtr)
    NumPut('Ptr', ObjPtrAddRef(funcObj),
           'Int', paramCount, p)
    ; Remember where that reference lives; FreeSyncCallback() undoes it.
    SyncCallbackRegistry.entries[pcb] := p
    return pcb

    RegisterSyncCallback_Msg(wParam, lParam, msg, hwnd) {
        if hwnd != wnd.hwnd {
            return
        }
        fn := ObjFromPtrAddRef(NumGet(lParam, 'Ptr'))
        paramCount := NumGet(lParam, A_PtrSize, 'Int')
        params := []
        Loop paramCount {
            params.Push(NumGet(wParam, A_PtrSize * (A_Index - 1), 'Ptr'))
        }
        return fn(params*)
    }
}

class DarkTheme
{
    static DarkColors := Map('Background', 0x202020, 'Controls', 0x404040, 'Font', 0xE0E0E0)
         , TextBackgroundBrush := DllCall('CreateSolidBrush', 'UInt', this.DarkColors['Background'], 'Ptr')
         , PreferredAppMode := Map('Default', 0, 'AllowDark', 1, 'ForceDark', 2, 'ForceLight', 3, 'Max', 4)
         , DarkByHwnd := Map()
         , HooksSet := false

    static SetWindowTheme(GuiObj, DarkMode := true)
    {
        static GWL_STYLE     := -16
             , ES_MULTILINE  := 0x0004
             , GetWindowLong := 'GetWindowLong' . (A_PtrSize = 8 ? 'Ptr' : '')
             , LV_Init       := false

        this._SetWindowAttribute(GuiObj, DarkMode)
        Mode_Explorer  := (DarkMode ? 'DarkMode_Explorer'  : 'Explorer' )
        Mode_CFD       := (DarkMode ? 'DarkMode_CFD'       : 'CFD'      )
        Mode_ItemsView := (DarkMode ? 'DarkMode_ItemsView' : 'ItemsView')

        for hWnd, GuiCtrlObj in GuiObj {
            switch GuiCtrlObj.Type, false
            {
                case 'Button', 'CheckBox', 'ListBox', 'UpDown':
                    DllCall('uxtheme\SetWindowTheme', 'Ptr', GuiCtrlObj.hWnd, 'Str', Mode_Explorer, 'Ptr', 0)
                
                case 'Edit':
                    res := DllCall(GetWindowLong, 'Ptr', GuiCtrlObj.hWnd, 'Int', GWL_STYLE) & ES_MULTILINE
                    DllCall('uxtheme\SetWindowTheme', 'Ptr', GuiCtrlObj.hWnd, 'Str', res ? Mode_Explorer : Mode_CFD, 'Ptr', 0)
                
                case 'ComboBox', 'DDL': DllCall('uxtheme\SetWindowTheme', 'Ptr', GuiCtrlObj.hWnd, 'Str', Mode_CFD, 'Ptr', 0)
            }
        }
        if !this.HooksSet {
            OnMessage(0x0133, ObjBindMethod(this, 'WM_CTLCOLOR'))       ; EDIT
            OnMessage(0x0134, ObjBindMethod(this, 'WM_CTLCOLOR'))       ; LISTBOX
            OnMessage(0x0135, ObjBindMethod(this, 'WM_CTLCOLORBTN'))    ; BUTTON
            OnMessage(0x0138, ObjBindMethod(this, 'WM_CTLCOLORSTATIC')) ; STATIC
            OnMessage(0x0082, ObjBindMethod(this, 'WM_NCDESTROY'))      ; cleanup
            this.HooksSet := true
        }
        this.DarkByHwnd[GuiObj.Hwnd] := DarkMode
    }

    static _SetWindowAttribute(GuiObj, DarkMode := true)
    {
        if (VerCompare(A_OSVersion, '10.0.17763') >= 0) {
            DWMWA_USE_IMMERSIVE_DARK_MODE := 19
            if VerCompare(A_OSVersion, '10.0.18985') >= 0 {
                DWMWA_USE_IMMERSIVE_DARK_MODE := 20
            }
            uxtheme := DllCall('GetModuleHandle', 'Str', 'uxtheme', 'Ptr')
            SetPreferredAppMode := DllCall('GetProcAddress', 'Ptr', uxtheme, 'Ptr', 135, 'Ptr')
            FlushMenuThemes     := DllCall('GetProcAddress', 'Ptr', uxtheme, 'Ptr', 136, 'Ptr')
            DllCall('dwmapi\DwmSetWindowAttribute', 'Ptr', GuiObj.hWnd, 'Int', DWMWA_USE_IMMERSIVE_DARK_MODE, 'Int*', DarkMode, 'Int', 4)
            DllCall(SetPreferredAppMode, 'Int', this.PreferredAppMode[DarkMode ? 'ForceDark' : 'Default'])
            DllCall(FlushMenuThemes)
            GuiObj.BackColor := DarkMode ? this.DarkColors['Background'] : 'Default'
        }
    }

    static WM_CTLCOLOR(wParam, lParam, msg, hwnd) {
        if !this.DarkByHwnd.Has(hwnd) || !this.DarkByHwnd[hwnd]
            return
        DllCall('SetTextColor', 'Ptr', wParam, 'UInt', this.DarkColors['Font'])
        DllCall('SetBkColor', 'Ptr', wParam, 'UInt', this.DarkColors['Controls'])
        DllCall('SetDCBrushColor', 'Ptr', wParam, 'UInt', this.DarkColors['Controls'], 'UInt')
        return DllCall('GetStockObject', 'Int', 18, 'Ptr') ; DC_BRUSH
    }

    static WM_CTLCOLORBTN(wParam, lParam, msg, hwnd) {
        if !this.DarkByHwnd.Has(hwnd) || !this.DarkByHwnd[hwnd]
            return
        DllCall('SetDCBrushColor', 'Ptr', wParam, 'UInt', this.DarkColors['Background'], 'UInt')
        return DllCall('GetStockObject', 'Int', 18, 'Ptr')
    }

    static WM_CTLCOLORSTATIC(wParam, lParam, msg, hwnd) {
        if !this.DarkByHwnd.Has(hwnd) || !this.DarkByHwnd[hwnd]
            return
        DllCall('SetTextColor', 'Ptr', wParam, 'UInt', this.DarkColors['Font'])
        DllCall('SetBkColor', 'Ptr', wParam, 'UInt', this.DarkColors['Background'])
        return this.TextBackgroundBrush
    }

    static WM_NCDESTROY(wParam, lParam, msg, hwnd) {
        (this.DarkByHwnd.Has(hwnd) && this.DarkByHwnd.Delete(hwnd))
    }
}

; Where the program icon comes from: the executable itself once compiled,
; otherwise the icon file in the Resources folder next to the script. Without
; that file the standard AutoHotkey icon is used.
class AppIconSource
{
    static RELATIVE_PATH := 'Resources\GoogleTranslator.ico'

    static File {
        get {
            if A_IsCompiled {
                return A_ScriptFullPath
            }
            iconPath := A_ScriptDir . '\' . this.RELATIVE_PATH
            return FileExist(iconPath) ? iconPath : A_AhkPath
        }
    }
}

class Icons
{
    ; A button does not own the icon it shows, and BM_SETIMAGE does not free
    ; the previous one. Icons are therefore created once per name and size
    ; and kept for the life of the process instead of a new HICON per change.
    static Get(iconName, height := 0) {
        static cache := Map()
        cacheKey := iconName . '|' . height
        if !cache.Has(cacheKey) || !cache[cacheKey] {
            cache[cacheKey] := this.FromBase64(iconName, height)
        }
        return cache[cacheKey]
    }

    static FromBase64(iconName, height := 0) {
        base64 := this._data[iconName]
        size := StrLen( RTrim(base64, '=') )*3//4
        if DllCall('Crypt32\CryptStringToBinary', 'Str', base64, 'UInt', StrLen(base64), 'UInt', 1,
                                                  'Ptr', buf := Buffer(size), 'UIntP', &size, 'Ptr', 0, 'Ptr', 0)
            return DllCall('CreateIconFromResourceEx', 'Ptr', buf, 'UInt', size, 'UInt', true,
                                                       'UInt', 0x30000, 'Int', height, 'Int', height, 'UInt', 0, 'Ptr')
        return 0
    }

    static _data => Map(
        'swap', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAAHuSURBVDhPY2YgCtizMCvKe/9n53/K8PXlb6ggscCe
            RTSifbnxqi//pdJnHWQQteeBSoABAReANHsslg8piGBm52LgVTWUZ2D5Y/P5+6c1
            DK8f/gKpwGMAQjMTGwdYhJGREWLIz9+2nx99Xs3w7eEvJrAMFsCqyxcqZu0b8fvT
            W6gIBPz+8JpB2NDJlk9HsxDEx+mCf68kb7y+vH7x70/vmIWMnMygwgwvdi/efGd+
            g8/Pj+93MHx8+IcFKg4G/F7FycJGLlUgt/7/++fvq71Lspg5uN5DpcGAiY39M8OT
            E3egXAYUL/Aq67qKmHkoiZi6K4paeKtwyGjYQaVwAhQDmP7/Z4QyEeD///9QFhj8
            g9IwgDMQYeDboxuH3pzcduPt6V23357aeevL3Uu7oVJgAAkDGQtOhr+M8v9+/eQF
            86Hg74/vIl8f3nlyr7VLl4Hh4B+oMAoAO5nPOadWIbyoiZmTl4GVXwQsAQK/3j1n
            +PP1I8PNmSWRvy9tXQEVRgHgaPz5hfMcswCPjYCOtTwoscAAIzMLw9Pt85d+3ve2
            lYHhGkpYwAAkHQBTFDh5/vpjw6tiCDbk368fDA9X9y99vfJCPAPD6r9gdQQBMKNI
            pc48aLzy83/R8NYlDAyhBPIKNiCux80sb+dFnGYGBgBSf6zJ/d34XAAAAABJRU5E
            rkJggg==
        )',

        'play', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAAEGSURBVDhPY6AUMIIIE93F6v/FBboZ3n7bz8D0YebZ
            s+nfwLJEAGYQISEWls0ao5/OqCrkxvCbPUmS1fuflLTrpefPt/wGq8IDmEDEf0Yg
            zcTIwMjPychspyDJHKbTy6iqcsfYcGWhsfFMLrBKHABsADpg5Ocg2iCsBsAAwiBt
            nAbhNQAGEF7DNIgoA2AA2SAGMdmjIDGSDEAAUOz/B7NIMuD/xx///x568PzvqivF
            DK+eWIPEiDIAWeP/23dUzp4P74clNrwGIGtkefBGGVkjDGA1AJvGEyfCv0OlUQDY
            AMb/DP8Y/v0HavwO1vhv9dUiQhphACUz/X/3dR8bG+NMQpqoCBgYAA0OkC+cA+Y8
            AAAAAElFTkSuQmCC
        )',

        'pause', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAACMSURBVDhPY6AUMIIIE4u1BYySvP5gESj4/+rz0TNH
            g2tAbGPrda1MYjxWYAko+P/888YzJ4InsIA4IM1MrsoOYBko+HvwngSQAhvAKMsX
            wmSnqAZiw8C/3XdB1AQmMI8CMGrAqAEgMPAGgPMCKGNA0zYCADMTlMXw//GnNUB5
            lMz09/mHjVAmJYCBAQDiYSs0A4bFKwAAAABJRU5ErkJggg==
        )',

        'stop', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAABYSURBVDhPY6AUMIIIE4u1BYySvP5gESLB/+efN545
            ETwBbIBp4K79TK7KDmAZIsG/3XcPnF7v5sgE5ZMNRg0YNQAEBt4AsjPT3+cfNp47
            ETYByiUXMDAAAO/JGBr+FuT9AAAAAElFTkSuQmCC
        )',

        'translate', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAAFBSURBVDhPY2TABeRslBj+M0uB2Yx/nzE8OnIPzEYD
            2A0QtedRi6t6Jahmzgnifrhz+vvNBS1iDK8PfgHLIwEmKI0KmH5xcQhKcrJw8zOA
            MLugBCdIDCqLArAbQAIYNYAKBrBAaTBgVXbXZhWUNv//+zcfAxMzVBSYWIBsTgml
            KEZZ9U+/3z8/+fvuzqtQKdSEJOxR16wWUV3DxMIGFUEF//78Yrizsr3l9faGWqgQ
            A8IaIPh+58uR/1z/zQRUjFUYGNES6f9/DA93ztn54tGKDIbnz/9BRVENYGB4/u/z
            sw8bmTm53PkUdCWhgmDw9NCKc4+3zPFmuHvqO1QIDNAMAILvj399ePx2E7uIWDCP
            lKogSOjV2R33762a6Mzw5sg7sBqigIKjukb5vtca5QdeMyi4q0NFSQRytpJgjBMw
            MAAA9qthDoOuYEYAAAAASUVORK5CYII=
        )',
        
        'backward', '
        (LTrim Join
            iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAAXNSR0IArs4c6QAA
            AARnQU1BAACxjwv8YQUAAAHqSURBVDhPxZM9aFRBEMf/s+/dBcEISkwjRJCoYKOF
            GLE5UwRMJTZaJBoQxCLooZWdWNkphxq1zyWQRiSIhUYxioqCjY0fiBE7IzaKwuXt
            /J3dt5jTXGp/xdudzze7syPoBCmY5g6o74cDseTfY6zrDSBMHn/4O8FNVtDtx83t
            DMT1JW0J+ZHgJbzLbuCCFEnblqDJHoHehsi+pFkFPiLdIaCo4Ud+p0www6os6bwF
            D0SZfEVIA0XrJapVQHWvQOpm3xnt4Bc72EZ+lTVlgmZxTsRdjHvgOt/K6fYyI3Y8
            6bYKIcNRJr9zJFvnwt6yjyflc+ZyakVwYC1q9tehJIWgxbDEBBQ9YcHXCF/HYfFB
            t4IRuW/N6SdxHMomFLPJ8p+JlyiT/oodZj09H1j/5zDqPkVrJ6Z0QJRjhM5itHK3
            TDDlF+y7OTqQBVUP4GhlLsrtzDCTlj6Fkz3m99m60Bcv0diQ1lDTPfzM55O0zEPr
            T6ETMdig8GpYBQ3tkh7+MtWild8blJb9NcmGNekFcmseZbdQ6+a+K9rBZ8zdfutY
            S8r3z2Fzeiyit8ypVjqtBp/YQQ7iiPsWpOVZCJxnju3+pD2ss2bakrQl5IJVdRmb
            sgkMdhqmdsI4T3IbxG8FMsC3PuCYjbP8O87Ab3G/xS5B/sjNAAAAAElFTkSuQmCC
        )'
    )
}

class Config {
    ; Keep in sync with ;@Ahk2Exe-SetVersion at the top of the script:
    ; Tools\BuildRelease.ps1 refuses to build when they differ.
    static VERSION := '1.0.0'

    static API_KEYS := {
        translatePage : 'AIzaSyATBXajvzQLTDHEQbcpq0Ihe0vWDHmO520',
        dictionary    : 'AIzaSyA6EEtrDCfBkHV8uU2lgGY-N383ZgAOo7Y'
    }
    
    static URLS := {
        translatePage : 'https://translate-pa.googleapis.com/v1/translateHtml',
        dictionary    : 'https://dictionaryextension-pa.googleapis.com/v1/dictionaryExtensionData',
        languages     : 'https://translate.googleapis.com/translate_a/l?client=chrome'
    }
}
