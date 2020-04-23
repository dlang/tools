---
name: Bug report
about: Create a report to help us improve
title: ''
labels: Prio.3.Normal, Type.Bug
assignees: ''

---

**Describe the bug**
A clear and concise description of what the bug is.

**Platform**
If applicable, provide informations about the platform the bug triggers on.
*OS*: (Windows, Linux, Mac OSX, FreeBSD, Android, iOS, etc...)
*Compiler*: (DMD 2.091.1, LDC 1.20.1, DMD@1897da, etc...)
Any other tooling and version that is relevant (e.g. dub version, C++ compiler/version if the bugs concerns `extern(C++)`, etc...)

**To Reproduce**
A [Short, Self Contained, Correct Example](http://sscce.org/), and the expected behavior vs the actual one.
Please provide code examples, command example, and error messages when applicable.
E.g.
```D
void main () { /* Some code */ }
``` 
```console
$ dmd -unittest -run test.d
test.d(1): Error: cannot implicitly convert expression `a` of type `A` to `B`
```
Screenshot, links to repositories are also welcome, however bear in mind that anything that is self contained is less likely to disappear over time. Note that in order to reduce bugs, you can use [DustMite](https://github.com/CyberShadow/DustMite), which will reduce the bug for you. It is also available via `dub dustmite`.
