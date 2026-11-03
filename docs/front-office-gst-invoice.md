# Front office: GST tax invoice and registration card

Status: built in migration 168 (live). Not reviewed by an accountant. Everything marked ASSUMPTION must be confirmed locally before the first paying hotel uses it.

## What the system does
- One tax invoice per stay, issued after check-out (the folio is final). It is stored as a snapshot and a database trigger refuses any edit or delete. A mistake needs a credit note (NOT built yet).
- Number format `<prefix>/<yyzz>/<6 digits>`, e.g. FO/2627/000001. Consecutive per outlet per financial year (1 April start), 16 characters or fewer (CGST Rule 46).
- Supplier legal name, address and GSTIN on every invoice. A folio that carries GST cannot be invoiced without the hotel GSTIN.
- Recipient: guest by default, or a company name plus GSTIN. A bill of 50,000 or more to someone without a GSTIN needs their address and state code.
- Lines carry SAC, taxable value, rate and tax; a summary by SAC and rate shows CGST and SGST.
- The GSTIN must be 15 characters in the standard pattern and its first two digits must match the state code.
- Sales register (`fo_invoice_register`) for the accountant, up to one year per run. No screen yet.

## Rates the system uses (ASSUMPTIONS, confirm)
| Item | Value | Note |
|---|---|---|
| Room up to 7,500 per night | 5% | Higher band is 18% |
| Room below 1,000 per night | 0% | Sources conflict; the limit is a setting (`room_tax_exempt_below`) |
| Other charges | 5% | A hotel classed as "specified premises" may need 18% on restaurant services |
| SAC | 996311 room, 996331 restaurant and room service, 999711 laundry, 999799 other | |
| Place of supply | The hotel's own state, so CGST plus SGST only | Immovable-property rule; confirm |

## Not built
- E-invoicing (IRN and QR). Needed above the e-invoice turnover limit when billing a GST-registered business. Confirm the limit that applies.
- Credit notes for invoiced folios.
- Amount in words, HSN summary tweaks, and any state-specific cess or luxury tax.

## Confirm with a local accountant before launch
1. Room tax slabs and the no-GST band.
2. Rate for food and other services (5% versus 18%).
3. SAC codes.
4. Place of supply for guests from other states or countries.
5. E-invoice threshold and whether this hotel is already inside it.
6. Invoice series rules for a hotel with more than one outlet.
