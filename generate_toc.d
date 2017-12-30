import arsd.dom;
import std.algorithm;
import std.file;
import std.stdio;

void main(string[] args) {
	auto document = new Document(readText(args[1]));

	/+
	// Displays all the links that start with http
	foreach(element; document["a[href^=http]"])
		writeln(element.href);

	// Displays all the headers (NOT in the order they appear btw)
	foreach(element; document["h1, h2, h3, h4, h5, h6"])
		writeln(element.innerText);

	// Fetch the text of all the dcode segments
	foreach(element; document["pre.d_code"])
		writeln(element.innerText);
	+/

	writeln(generateToc(document));
}

Element generateToc(Document document) {
	auto toc = Element.make("ol");

	foreach(element; document.root.tree) {
		if(element.tagName.among("h1", "h2", "h3", "h4", "h5", "h6")) {
			auto anchor = element.querySelector("[name], [id]");
			if(anchor !is null) {
				auto anchorText = anchor.hasAttribute("id") ? anchor.attrs.id : anchor.attrs.name;
				toc.appendText("\n\t"); // just trying to pretty-format it a little
				toc.addChild("li", Element.make("a", element.innerText, "#" ~ anchorText));
			} else
				stderr.writeln("WARNING: no anchor for heading ", element);
		}
	}

	toc.appendText("\n"); // pretty formatting for human reading of the html output

	return toc;
}
