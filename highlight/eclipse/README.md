# Landin for Eclipse

Install Eclipse's TM4E support, open **Preferences → TextMate → Grammars**, and
add `../textmate/syntaxes/landin.tmLanguage.json` for the `.ldn` content type.
Open Landin files with the Generic Editor. This uses Eclipse's maintained
TextMate integration instead of carrying a second Java lexer or an OSGi plugin
whose only job would be to embed the same grammar.
