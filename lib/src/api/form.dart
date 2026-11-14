part of 'document.dart';

/// Text alignment of a text field, like pdf-lib's `TextAlignment`.
enum TextAlignment { left, center, right }

/// Image alignment of `setImage`, like pdf-lib's `ImageAlignment`.
enum ImageAlignment { left, center, right }

// field flags (pdf-lib's `flags.ts`)
const int _readOnly = 1;
const int _required = 1 << 1;
const int _noExport = 1 << 2;
const int _noToggleToOff = 1 << 14;
const int _radiosInUnison = 1 << 25;
const int _multiline = 1 << 12;
const int _password = 1 << 13;
const int _fileSelect = 1 << 20;
const int _doNotSpellCheck = 1 << 22;
const int _doNotScroll = 1 << 23;
const int _comb = 1 << 24;
const int _richText = 1 << 25;
const int _edit = 1 << 18;
const int _sort = 1 << 19;
const int _multiSelect = 1 << 21;
const int _commitOnSelChange = 1 << 26;

final Expando<PDFForm> _forms = Expando<PDFForm>();

/// The result of one form call: a number and the output records.
typedef _FormResult = ({int value, FormReader? out});

extension on PDFDocument {
  _FormResult _form(
    int op, {
    int field = 0,
    List<double> nums = const <double>[],
    List<String> strings = const <String>[],
  }) {
    Float64List input = Float64List.fromList(nums);
    Uint8List bytes = encodeStrings(strings);
    Int64List out = Int64List(2);
    check(
      doxPdfForm(
        _handle,
        op,
        field,
        input.address,
        input.length,
        bytes.address,
        bytes.length,
        out.address,
      ),
    );
    return (
      value: out[0],
      out: out[1] == 0 ? null : FormReader(takeBytes(out[1])),
    );
  }
}

/// Forms, like pdf-lib's `PDFDocument.getForm`.
extension PDFDocumentForm on PDFDocument {
  /// The form of this document. Made when the document has none. XFA data
  /// is removed, like pdf-lib (it can not read or write XFA).
  ///
  /// After this call, [save] updates the field appearances (unless
  /// `updateFieldAppearances: false`), like pdf-lib.
  PDFForm getForm() {
    _form(opGetForm);
    return _forms[this] ??= PDFForm._(this);
  }

  /// The page whose `/Annots` has the annotation [ref], like pdf-lib's
  /// `findPageForAnnotationRef`.
  PDFPage? findPageForAnnotationRef(int ref) {
    int page = _form(opPageOfAnnot, field: ref).value;
    return page == 0 ? null : _page(page);
  }
}

/// The interactive form (AcroForm) of a document, like pdf-lib's
/// `PDFForm`. Get it with [PDFDocumentForm.getForm].
class PDFForm {
  PDFForm._(this.doc);

  final PDFDocument doc;

  bool hasXFA() => doc._form(opHasXfa).value == 1;

  void deleteXFA() => doc._form(opDeleteXfa);

  PDFField _field(int ref, int kind) => switch (kind) {
    fieldButton => PDFButton._(doc, ref),
    fieldCheckBox => PDFCheckBox._(doc, ref),
    fieldDropdown => PDFDropdown._(doc, ref),
    fieldOptionList => PDFOptionList._(doc, ref),
    fieldRadioGroup => PDFRadioGroup._(doc, ref),
    fieldSignature => PDFSignature._(doc, ref),
    _ => PDFTextField._(doc, ref),
  };

  List<PDFField> _fields(FormReader? r) {
    if (r == null) return <PDFField>[];
    return <PDFField>[
      for (int i = r.int64(); i > 0; i--) _field(r.int64(), r.int64()),
    ];
  }

  /// All fields of the form, in tree order.
  List<PDFField> getFields() => _fields(doc._form(opGetFields).out);

  /// The field with the fully qualified [name], or null.
  PDFField? getFieldMaybe(String name) {
    List<PDFField> found = _fields(
      doc._form(opFindField, strings: <String>[name]).out,
    );
    return found.isEmpty ? null : found.first;
  }

  /// The field with the fully qualified [name]. Throws
  /// [NoSuchFieldError] when there is none.
  PDFField getField(String name) =>
      getFieldMaybe(name) ?? (throw NoSuchFieldError(name));

  T _typed<T extends PDFField>(String name, String type) {
    PDFField field = getField(name);
    if (field is T) return field;
    throw UnexpectedFieldTypeError(name, type, field.runtimeType.toString());
  }

  PDFButton getButton(String name) => _typed<PDFButton>(name, 'PDFButton');

  PDFCheckBox getCheckBox(String name) =>
      _typed<PDFCheckBox>(name, 'PDFCheckBox');

  PDFDropdown getDropdown(String name) =>
      _typed<PDFDropdown>(name, 'PDFDropdown');

  PDFOptionList getOptionList(String name) =>
      _typed<PDFOptionList>(name, 'PDFOptionList');

  PDFRadioGroup getRadioGroup(String name) =>
      _typed<PDFRadioGroup>(name, 'PDFRadioGroup');

  PDFSignature getSignature(String name) =>
      _typed<PDFSignature>(name, 'PDFSignature');

  PDFTextField getTextField(String name) =>
      _typed<PDFTextField>(name, 'PDFTextField');

  PDFField _create(int kind, String name) {
    FormReader r = doc
        ._form(
          opCreateField,
          nums: <double>[kind.toDouble()],
          strings: <String>[name],
        )
        .out!;
    return _fields(r).first;
  }

  /// A new push button. [name] may have parents: `a.b.button`.
  PDFButton createButton(String name) =>
      _create(fieldButton, name) as PDFButton;

  PDFCheckBox createCheckBox(String name) =>
      _create(fieldCheckBox, name) as PDFCheckBox;

  PDFDropdown createDropdown(String name) =>
      _create(fieldDropdown, name) as PDFDropdown;

  PDFOptionList createOptionList(String name) =>
      _create(fieldOptionList, name) as PDFOptionList;

  PDFRadioGroup createRadioGroup(String name) =>
      _create(fieldRadioGroup, name) as PDFRadioGroup;

  PDFTextField createTextField(String name) =>
      _create(fieldTextField, name) as PDFTextField;

  /// Draws every field on its page and removes all fields. With
  /// [updateFieldAppearances] (the default), appearances are updated first.
  void flatten({bool updateFieldAppearances = true}) =>
      doc._form(opFlatten, nums: <double>[updateFieldAppearances ? 1 : 0]);

  /// Removes [field] and its widgets.
  void removeField(PDFField field) =>
      doc._form(opRemoveField, field: field.ref);

  /// Makes new appearances for the fields that need them (changed, or
  /// without one). [font] defaults to [getDefaultFont] (Helvetica, a
  /// WinAnsi font).
  void updateFieldAppearances([PDFFont? font]) => doc._form(
    opUpdateAppearances,
    nums: <double>[(font?.ref ?? 0).toDouble()],
  );

  void markFieldAsDirty(int fieldRef) =>
      doc._form(opMarkDirty, field: fieldRef);

  void markFieldAsClean(int fieldRef) =>
      doc._form(opMarkClean, field: fieldRef);

  bool fieldIsDirty(int fieldRef) =>
      doc._form(opIsDirty, field: fieldRef).value == 1;

  /// Helvetica, embedded once per document.
  PDFFont getDefaultFont() =>
      PDFFont._(doc, doc._form(opDefaultFont).value, StandardFonts.helvetica);
}

/// One widget annotation of a field (read only), like pdf-lib's
/// `PDFWidgetAnnotation`.
class PDFWidgetAnnotation {
  PDFWidgetAnnotation._(
    this.ref,
    this._rect,
    this._page,
    this._flags,
    this._onValue,
    this._state,
  );

  /// The object number of the widget, `number << 16 | generation`.
  final int ref;
  final PDFBox _rect;
  final int _page;
  final int _flags;
  final String? _onValue;
  final String? _state;

  PDFBox getRectangle() => _rect;

  /// The ref of the page of the widget, or null when no page has it.
  int? P() => _page == 0 ? null : _page;

  int getFlags() => _flags;

  /// The "on" state name of a check box or radio button widget.
  String? getOnValue() => _onValue;

  String? getAppearanceState() => _state;
}

/// The low level field, like pdf-lib's `PDFAcroField`. Here it only gives
/// the widgets.
class PDFAcroField {
  PDFAcroField._(this._doc, this.ref);

  final PDFDocument _doc;
  final int ref;

  List<PDFWidgetAnnotation> getWidgets() {
    FormReader r = _doc._form(opWidgets, field: ref).out!;
    return <PDFWidgetAnnotation>[
      for (int i = r.int64(); i > 0; i--)
        PDFWidgetAnnotation._(
          r.int64(),
          (
            x: r.float64(),
            y: r.float64(),
            width: r.float64(),
            height: r.float64(),
          ),
          r.int64(),
          r.int64(),
          r.optString(),
          r.optString(),
        ),
    ];
  }

  String getFullyQualifiedName() =>
      _doc._form(opName, field: ref).out!.string();
}

/// The [backgroundColor] etc. of `addToPage`, as numbers for Rust.
List<double> _widgetNums(
  PDFPage page, {
  required double x,
  required double y,
  required double width,
  required double height,
  Color? textColor,
  Color? backgroundColor,
  Color? borderColor,
  required double borderWidth,
  Rotation? rotate,
  bool? hidden,
  PDFFont? font,
}) => <double>[
  page.ref.toDouble(),
  x,
  y,
  width,
  height,
  ..._color(textColor),
  ..._color(backgroundColor),
  ..._color(borderColor),
  borderWidth,
  rotate == null ? 0 : toDegrees(rotate),
  hidden == true ? 1 : 0,
  (font?.ref ?? 0).toDouble(),
];

void _checkPositive(double value, String name) {
  if (value < 0 || value.isNaN) {
    throw PDFLibError(
      '`$name` must be a positive number or 0, but was actually $value',
    );
  }
}

/// A form field, like pdf-lib's `PDFField`.
class PDFField {
  PDFField._(this.doc, this.ref) : acroField = PDFAcroField._(doc, ref);

  final PDFDocument doc;

  /// The object number of the field, `number << 16 | generation`.
  final int ref;

  final PDFAcroField acroField;

  _FormResult _call(
    int op, {
    List<double> nums = const <double>[],
    List<String> strings = const <String>[],
  }) => doc._form(op, field: ref, nums: nums, strings: strings);

  int _flags() => _call(opFlags).value;

  bool _hasFlag(int flag) => _flags() & flag != 0;

  void _setFlag(int flag, bool on, {bool dirty = false}) => _call(
    opSetFlag,
    nums: <double>[flag.toDouble(), on ? 1 : 0, dirty ? 1 : 0],
  );

  /// The fully qualified name, eg. `page1.address.city`.
  String getName() => _call(opName).out!.string();

  bool isReadOnly() => _hasFlag(_readOnly);
  void enableReadOnly() => _setFlag(_readOnly, true);
  void disableReadOnly() => _setFlag(_readOnly, false);

  bool isRequired() => _hasFlag(_required);
  void enableRequired() => _setFlag(_required, true);
  void disableRequired() => _setFlag(_required, false);

  bool isExported() => !_hasFlag(_noExport);
  void enableExporting() => _setFlag(_noExport, false);
  void disableExporting() => _setFlag(_noExport, true);

  /// True when [PDFForm.updateFieldAppearances] would make new appearances.
  bool needsAppearancesUpdate() => _call(opNeedsUpdate).value == 1;

  void defaultUpdateAppearances(PDFFont font) => _update(font);

  void _update([PDFFont? font]) =>
      _call(opUpdateField, nums: <double>[(font?.ref ?? 0).toDouble()]);

  void _addToPage(List<double> nums, [String text = '']) =>
      _call(opAddToPage, nums: nums, strings: <String>[text]);

  void _setFontSize(double fontSize) {
    _checkPositive(fontSize, 'fontSize');
    _call(opFontSizeSet, nums: <double>[fontSize]);
  }
}

/// A text field, like pdf-lib's `PDFTextField`.
class PDFTextField extends PDFField {
  PDFTextField._(super.doc, super.ref) : super._();

  /// The text, or null. Throws [RichTextFieldReadError] for a rich text
  /// field with no value.
  String? getText() => _call(opTextGet).out!.optString();

  /// Sets the text; null or '' removes it. Throws [ExceededMaxLengthError]
  /// when it is longer than [getMaxLength].
  void setText(String? text) => _call(
    opTextSet,
    strings: text == null || text.isEmpty ? const <String>[] : <String>[text],
  );

  TextAlignment getAlignment() =>
      TextAlignment.values[_call(opAlignmentGet).value];

  void setAlignment(TextAlignment alignment) =>
      _call(opAlignmentSet, nums: <double>[alignment.index.toDouble()]);

  int? getMaxLength() {
    int v = _call(opMaxLengthGet).value;
    return v < 0 ? null : v;
  }

  /// Sets the max length; null removes it.
  void setMaxLength([int? maxLength]) {
    if (maxLength != null && maxLength < 0) {
      throw RangeError(
        '`maxLength` must be at least 0 and at most 9007199254740991, but '
        'was actually $maxLength',
      );
    }
    _call(opMaxLengthSet, nums: <double>[(maxLength ?? -1).toDouble()]);
  }

  void removeMaxLength() => setMaxLength();

  /// Shows [image] in every widget, aligned like the text.
  void setImage(PDFImage image) => _call(
    opSetImage,
    nums: <double>[image.ref.toDouble(), getAlignment().index.toDouble()],
  );

  void setFontSize(double fontSize) => _setFontSize(fontSize);

  bool isMultiline() => _hasFlag(_multiline);
  void enableMultiline() => _setFlag(_multiline, true, dirty: true);
  void disableMultiline() => _setFlag(_multiline, false, dirty: true);

  bool isPassword() => _hasFlag(_password);
  void enablePassword() => _setFlag(_password, true);
  void disablePassword() => _setFlag(_password, false);

  bool isFileSelector() => _hasFlag(_fileSelect);
  void enableFileSelection() => _setFlag(_fileSelect, true);
  void disableFileSelection() => _setFlag(_fileSelect, false);

  bool isSpellChecked() => !_hasFlag(_doNotSpellCheck);
  void enableSpellChecking() => _setFlag(_doNotSpellCheck, false);
  void disableSpellChecking() => _setFlag(_doNotSpellCheck, true);

  bool isScrollable() => !_hasFlag(_doNotScroll);
  void enableScrolling() => _setFlag(_doNotScroll, false);
  void disableScrolling() => _setFlag(_doNotScroll, true);

  bool isCombed() {
    int f = _flags();
    return f & _comb != 0 &&
        f & (_multiline | _password | _fileSelect) == 0 &&
        getMaxLength() != null;
  }

  /// Puts each character in its own cell. Needs a max length.
  void enableCombing() {
    disableMultiline();
    disablePassword();
    disableFileSelection();
    _setFlag(_comb, true, dirty: true);
  }

  void disableCombing() => _setFlag(_comb, false, dirty: true);

  bool isRichFormatted() => _hasFlag(_richText);
  void enableRichFormatting() => _setFlag(_richText, true);
  void disableRichFormatting() => _setFlag(_richText, false);

  /// Adds a widget of this field to [page]. Defaults as in pdf-lib.
  void addToPage(
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    PDFFont? font,
    bool? hidden,
  }) => _addToPage(
    _widgetNums(
      page,
      x: x ?? 0,
      y: y ?? 0,
      width: width ?? 200,
      height: height ?? 50,
      textColor: textColor ?? const RGB(0, 0, 0),
      backgroundColor: backgroundColor ?? const RGB(1, 1, 1),
      borderColor: borderColor ?? const RGB(0, 0, 0),
      borderWidth: borderWidth ?? 1,
      rotate: rotate,
      hidden: hidden,
      font: font,
    ),
  );

  void updateAppearances(PDFFont font) => _update(font);
}

/// A check box, like pdf-lib's `PDFCheckBox`.
class PDFCheckBox extends PDFField {
  PDFCheckBox._(super.doc, super.ref) : super._();

  void check() => _call(opCheck);

  void uncheck() => _call(opUncheck);

  bool isChecked() => _call(opIsChecked).value == 1;

  void addToPage(
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    bool? hidden,
  }) => _addToPage(
    _widgetNums(
      page,
      x: x ?? 0,
      y: y ?? 0,
      width: width ?? 50,
      height: height ?? 50,
      textColor: textColor ?? const RGB(0, 0, 0),
      backgroundColor: backgroundColor ?? const RGB(1, 1, 1),
      borderColor: borderColor ?? const RGB(0, 0, 0),
      borderWidth: borderWidth ?? 1,
      rotate: rotate,
      hidden: hidden,
    ),
  );

  void updateAppearances() => _update();
}

/// A radio group, like pdf-lib's `PDFRadioGroup`.
class PDFRadioGroup extends PDFField {
  PDFRadioGroup._(super.doc, super.ref) : super._();

  List<String> getOptions() => _call(opRadioOptions).out!.strings();

  String? getSelected() => _call(opRadioSelected).out!.optString();

  /// Selects [option]; it must be one of [getOptions].
  void select(String option) => _call(opRadioSelect, strings: <String>[option]);

  void clear() => _call(opRadioClear);

  bool isOffToggleable() => !_hasFlag(_noToggleToOff);
  void enableOffToggling() => _setFlag(_noToggleToOff, false);
  void disableOffToggling() => _setFlag(_noToggleToOff, true);

  bool isMutuallyExclusive() => !_hasFlag(_radiosInUnison);
  void enableMutualExclusion() => _setFlag(_radiosInUnison, false);
  void disableMutualExclusion() => _setFlag(_radiosInUnison, true);

  /// Adds a radio button for [option] to [page].
  void addOptionToPage(
    String option,
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    bool? hidden,
  }) => _addToPage(
    _widgetNums(
      page,
      x: x ?? 0,
      y: y ?? 0,
      width: width ?? 50,
      height: height ?? 50,
      textColor: textColor ?? const RGB(0, 0, 0),
      backgroundColor: backgroundColor ?? const RGB(1, 1, 1),
      borderColor: borderColor ?? const RGB(0, 0, 0),
      borderWidth: borderWidth ?? 1,
      rotate: rotate,
      hidden: hidden,
    ),
    option,
  );

  void updateAppearances() => _update();
}

List<String> _optionList(Object options) => switch (options) {
  String s => <String>[s],
  List<String> l => l,
  _ => throw ArgumentError.value(
    options,
    'options',
    'must be a String or a List<String>',
  ),
};

/// The shared parts of [PDFDropdown] and [PDFOptionList].
abstract class _PDFChoice extends PDFField {
  _PDFChoice._(super.doc, super.ref) : super._();

  bool get _marksDirty;

  List<String> getOptions() => _call(opChoiceOptions).out!.strings();

  List<String> getSelected() => _call(opChoiceSelected).out!.strings();

  /// Replaces the options.
  void setOptions(List<String> options) => _call(
    opChoiceSetOptions,
    nums: <double>[_marksDirty ? 1 : 0],
    strings: options,
  );

  /// Adds one option (a String) or many (a `List<String>`).
  void addOptions(Object options) => _call(
    opChoiceAddOptions,
    nums: <double>[_marksDirty ? 1 : 0],
    strings: _optionList(options),
  );

  /// Selects one option (a String) or many (a `List<String>`). With
  /// [merge], the earlier selection stays.
  void select(Object options, [bool merge = false]) => _call(
    opChoiceSelect,
    nums: <double>[merge ? 1 : 0],
    strings: _optionList(options),
  );

  void clear() => _call(opChoiceClear);

  void setFontSize(double fontSize) => _setFontSize(fontSize);

  bool isSorted() => _hasFlag(_sort);
  void enableSorting() => _setFlag(_sort, true);
  void disableSorting() => _setFlag(_sort, false);

  bool isMultiselect() => _hasFlag(_multiSelect);
  void enableMultiselect() => _setFlag(_multiSelect, true);
  void disableMultiselect() => _setFlag(_multiSelect, false);

  bool isSelectOnClick() => _hasFlag(_commitOnSelChange);
  void enableSelectOnClick() => _setFlag(_commitOnSelChange, true);
  void disableSelectOnClick() => _setFlag(_commitOnSelChange, false);

  void _addChoiceToPage(
    PDFPage page,
    double defaultHeight, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    PDFFont? font,
    bool? hidden,
  }) => _addToPage(
    _widgetNums(
      page,
      x: x ?? 0,
      y: y ?? 0,
      width: width ?? 200,
      height: height ?? defaultHeight,
      textColor: textColor ?? const RGB(0, 0, 0),
      backgroundColor: backgroundColor ?? const RGB(1, 1, 1),
      borderColor: borderColor ?? const RGB(0, 0, 0),
      borderWidth: borderWidth ?? 1,
      rotate: rotate,
      hidden: hidden,
      font: font,
    ),
  );

  void updateAppearances(PDFFont font) => _update(font);
}

/// A dropdown (combo box), like pdf-lib's `PDFDropdown`.
class PDFDropdown extends _PDFChoice {
  PDFDropdown._(super.doc, super.ref) : super._();

  @override
  bool get _marksDirty => false;

  bool isEditable() => _hasFlag(_edit);
  void enableEditing() => _setFlag(_edit, true);
  void disableEditing() => _setFlag(_edit, false);

  bool isSpellChecked() => !_hasFlag(_doNotSpellCheck);
  void enableSpellChecking() => _setFlag(_doNotSpellCheck, false);
  void disableSpellChecking() => _setFlag(_doNotSpellCheck, true);

  void addToPage(
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    PDFFont? font,
    bool? hidden,
  }) => _addChoiceToPage(
    page,
    50,
    x: x,
    y: y,
    width: width,
    height: height,
    textColor: textColor,
    backgroundColor: backgroundColor,
    borderColor: borderColor,
    borderWidth: borderWidth,
    rotate: rotate,
    font: font,
    hidden: hidden,
  );
}

/// An option list (list box), like pdf-lib's `PDFOptionList`.
class PDFOptionList extends _PDFChoice {
  PDFOptionList._(super.doc, super.ref) : super._();

  @override
  bool get _marksDirty => true;

  void addToPage(
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    PDFFont? font,
    bool? hidden,
  }) => _addChoiceToPage(
    page,
    100,
    x: x,
    y: y,
    width: width,
    height: height,
    textColor: textColor,
    backgroundColor: backgroundColor,
    borderColor: borderColor,
    borderWidth: borderWidth,
    rotate: rotate,
    font: font,
    hidden: hidden,
  );
}

/// A push button, like pdf-lib's `PDFButton`.
class PDFButton extends PDFField {
  PDFButton._(super.doc, super.ref) : super._();

  /// Shows [image] in every widget.
  void setImage(
    PDFImage image, [
    ImageAlignment alignment = ImageAlignment.center,
  ]) => _call(
    opSetImage,
    nums: <double>[image.ref.toDouble(), alignment.index.toDouble()],
  );

  void setFontSize(double fontSize) => _setFontSize(fontSize);

  /// Adds a widget with the caption [text] to [page]. Defaults as in
  /// pdf-lib (a gray background, no border).
  void addToPage(
    String text,
    PDFPage page, {
    double? x,
    double? y,
    double? width,
    double? height,
    Color? textColor,
    Color? backgroundColor,
    Color? borderColor,
    double? borderWidth,
    Rotation? rotate,
    PDFFont? font,
    bool? hidden,
  }) => _addToPage(
    _widgetNums(
      page,
      x: (x ?? 0) - (borderWidth ?? 0) / 2,
      y: (y ?? 0) - (borderWidth ?? 0) / 2,
      width: width ?? 100,
      height: height ?? 50,
      textColor: textColor ?? const RGB(0, 0, 0),
      backgroundColor: backgroundColor ?? const RGB(0.75, 0.75, 0.75),
      borderColor: borderColor,
      borderWidth: borderWidth ?? 0,
      rotate: rotate,
      hidden: hidden,
      font: font,
    ),
    text,
  );

  void updateAppearances(PDFFont font) => _update(font);
}

/// A signature field, like pdf-lib's `PDFSignature`. It can only be read,
/// flagged and removed.
class PDFSignature extends PDFField {
  PDFSignature._(super.doc, super.ref) : super._();
}
