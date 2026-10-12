# Upstream library references

These are byte-for-byte copies of the upstream revisions recorded in the
temporary target-library adapter headers. They are reference material outside
the configured compiler input library. Traits and other unsupported features
in these copies do not enter the pilot's input language.

| Module | Revision | SHA256 |
| --- | --- | --- |
| int | 7cb72f355a82474c386cb95f524f6fe98612624d | 2b9dd588eaac0b90be4bfe80f5e7f1833f938f2968eaac501e61fedf292605f6 |
| float | 2f5795cc750200a97115dfe5a637f5c4e6e47ddb | 234b1d2ee47b741c4cb78199c72cf0620ce482f6ece06e6c53557124f2875506 |
| string | 2f5795cc750200a97115dfe5a637f5c4e6e47ddb | 9e45bace6dfff8b749c5d3782fb3ab3608c7044196f02c02019370c045597d5a |
| io | 2f5795cc750200a97115dfe5a637f5c4e6e47ddb | 0b03d7da352c04c2495a9edc84496a3bdd74b445dc74022d6076891e3a007020 |
| bool | 2f5795cc750200a97115dfe5a637f5c4e6e47ddb | 5e05632dafd374459772f4500045dc1a876a5352ae13a87b576b251ac5bff8fc |

Keep active operations in `../../standard_library_temp/`. Enable a reference
implementation there only when the pilot supports its dependencies and the
operation has an executable example and granular tests. Concrete native
primitives remain explicit, checked builtin declarations.
