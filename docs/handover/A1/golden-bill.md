# Golden numbers for the discount block and the points discount (WS-DB -> WS-A1)

These numbers come from the database itself (`app.calc_bill` after migration 141, applied on a PostgreSQL 16 test database), not from a calculation by hand.
The database is the oracle: `LIB/calc-bill.ts` must return exactly these figures. The full input / output of every case is in
`docs/handover/A1/calc-bill-golden-141.json` (`input` = what `calc_bill` receives, `output` = what it returns, as the database prints it).
To merge into `calc-bill.golden.json`: copy `input`; `expected` = `{grand_total, tax_total, service_charge, discount, senior_discount, rounding}` from `output`
(the existing test compares those six keys), plus `discountable_subtotal` / `loyalty_discount` when present.

## Correction to the plan

The plan (and the header of an earlier draft of migration 141) says the worked example gives **232.40**. The database says **212.40**:
restricted A 100 + B 100, 18% exclusive, typed discount 20 -> A 100 + 18.00 tax = 118.00; B (100 - 20) = 80 + 14.40 tax = 94.40; total 118.00 + 94.40 = **212.40**
(tax 32.40). Case G1. The header of migration 141 now says 212.40.

## The rules the TypeScript mirror must follow (exactly what `app.calc_bill` does)

Input: each line may carry `"no_disc": true` (the dish, or the dish its size belongs to, is "not discountable"); the bill may carry `"discount"` (typed, >= 0) and `"loyalty_discount"` (points as money, >= 0).

1. Pass 1: line subtotal = round(price x qty, 2). The **pool** is the sum of the subtotals of the lines **without** `no_disc`. The **largest eligible line** is the first line with the
   largest subtotal among the eligible ones (a later line only wins with a strictly larger subtotal).
2. `manual = min(discount, pool)`; `loy = min(loyalty_discount, pool - manual)`; the amount spread is `manual + loy`.
3. Every eligible line except the largest gets round(spread x line subtotal / pool, 2); restricted lines get 0; the largest eligible line gets the rest (spread minus the others).
   If that leaves the largest line below 0 or above its own subtotal (many tiny lines), the whole spread is redone to the paisa by largest remainder over the eligible lines (as in 121).
   If the pool is 0 nothing is spread.
4. Tax is computed per line as before, on the line value after its discount: a restricted line (discount 0) is taxed on its full price, an unrestricted line on its reduced value
   (tax-inclusive lines: the tax inside is recomputed on the reduced price). Service charge and cash rounding are unchanged.
5. Senior / PWD (`senior.share` / `rate`) is statutory and ignores `no_disc`; it still cannot be combined with `discount` or `loyalty_discount` (the existing messages).
6. **Output keys are conditional** (a bill without restricted lines and without points is byte-identical to before 141, so `calc-bill.golden.json` passes unchanged):
   - `discountable_subtotal` (the pool) is present **only when at least one line has `no_disc`** (it is 0 when all are restricted).
   - `loyalty_discount` (the points part actually applied, after the cap) is present **only when `loyalty_discount` > 0 was asked for** (it can be 0 after the cap: case G11).
   - `discount` in the output is the **typed part only**; the discount total stored on the order (`orders.discount_total`) is `discount + loyalty_discount`.
   - Per line, `discount` is that line's share of the whole spread (typed + points).

## Summary

| Case | Subtotal | discount (typed) | loyalty_discount | discountable_subtotal | Tax | Service charge | Rounding | Grand total |
|---|---|---|---|---|---|---|---|---|
| G1 | 200.00 | 20.00 | (absent) | 100.00 | 32.40 | 0.00 | 0.00 | 212.40 |
| G2 | 200.00 | 20.00 | (absent) | 100.00 | 32.40 | 0.00 | -0.40 | 212.00 |
| G3 | 200.00 | 20.00 | (absent) | (absent) | 32.40 | 0.00 | 0.00 | 212.40 |
| G4 | 160.00 | 0.00 | (absent) | 0.00 | 28.80 | 0.00 | 0.00 | 188.80 |
| G5 | 214.00 | 20.00 | (absent) | 107.00 | 12.69 | 0.00 | 0.00 | 194.00 |
| G6 | 600.00 | 10.00 | (absent) | 100.00 | 0.00 | 0.00 | 0.00 | 590.00 |
| G7 | 180.00 | 80.00 | (absent) | 80.00 | 18.00 | 0.00 | 0.00 | 118.00 |
| G8 | 160.00 | 0.00 | 40.00 | (absent) | 21.60 | 0.00 | 0.00 | 141.60 |
| G9 | 200.00 | 20.00 | 80.00 | 100.00 | 18.00 | 0.00 | 0.00 | 118.00 |
| G10 | 180.00 | 60.00 | 20.00 | 80.00 | 0.00 | 0.00 | 0.00 | 100.00 |
| G11 | 200.00 | 100.00 | 0.00 | 100.00 | 18.00 | 0.00 | 0.00 | 118.00 |
| G12 | 200.00 | 20.00 | (absent) | 100.00 | 34.02 | 9.00 | 0.00 | 223.02 |
| G13 | 4486.46 | 333.33 | (absent) | 3967.92 | 342.48 | 0.00 | 0.00 | 4294.85 |
| G14 | 100.00 | 0.00 | (absent) | 0.00 | 0.00 | 0.00 | 0.00 | 80.00 |
| G15 | 410.07 | 0.07 | (absent) | 10.07 | 0.00 | 0.00 | 0.00 | 410.00 |

## Cases

### G1

The plan's worked example, corrected: restricted A 100 + B 100, 18% exclusive (CGST 9 + SGST 9), typed discount 20, no cash rounding. The plan said 232.40; the database says 212.40 (100 + 80 + 32.40 tax = A 118.00 + B 94.40).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":20,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.00 / 118.00; 2: 20.00 / 14.40 / 94.40

Bill: subtotal 200.00, discount 20.00, discountable_subtotal 100.00, tax 32.40, service charge 0.00, rounding 0.00, **grand total 212.40**.

### G2

G1 with cash rounding to the nearest 1: grand 212.40 -> 212, rounding -0.40.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":20,"sc_percent":0,"sc_taxable":true,"rounding":"nearest_1"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.00 / 118.00; 2: 20.00 / 14.40 / 94.40

Bill: subtotal 200.00, discount 20.00, discountable_subtotal 100.00, tax 32.40, service charge 0.00, rounding -0.40, **grand total 212.00**.

### G3

Same bill, nothing restricted: the old rule (the discount is spread over both lines pro rata, 10 + 10). Output has NO discountable_subtotal key.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":20,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 10.00 / 16.20 / 106.20; 2: 10.00 / 16.20 / 106.20

Bill: subtotal 200.00, discount 20.00, tax 32.40, service charge 0.00, rounding 0.00, **grand total 212.40**.

### G4

All lines restricted: the typed discount 30 is cut to 0 (pool 0), tax on the full price, discountable_subtotal 0.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":80,"qty":2,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true}],"discount":30,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 28.80 / 188.80

Bill: subtotal 160.00, discount 0.00, discountable_subtotal 0.00, tax 28.80, service charge 0.00, rounding 0.00, **grand total 188.80**.

### G5

Mixed tax-inclusive: restricted 107 (7% inside) + unrestricted 107, discount 20: the restricted line keeps 107, the other pays 87 (its tax inside is recomputed on 87).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":107,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":7,"compound":false}],"no_disc":true},{"key":2,"price":107,"qty":1,"inclusive":true,"comps":[{"name":"VAT","rate":7,"compound":false}]}],"discount":20,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 7.00 / 107.00; 2: 20.00 / 5.69 / 87.00

Bill: subtotal 214.00, discount 20.00, discountable_subtotal 107.00, tax 12.69, service charge 0.00, rounding 0.00, **grand total 194.00**.

### G6

The rounding remainder goes to the largest ELIGIBLE line: a restricted 500 is the largest line of all, 33.33 / 33.33 / 33.34 share a discount of 10 -> 3.33, 3.33, 3.34 (the 33.34 line takes the extra cent).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":500,"qty":1,"inclusive":false,"comps":[],"no_disc":true},{"key":2,"price":33.33,"qty":1,"inclusive":false,"comps":[]},{"key":3,"price":33.33,"qty":1,"inclusive":false,"comps":[]},{"key":4,"price":33.34,"qty":1,"inclusive":false,"comps":[]}],"discount":10,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 0.00 / 500.00; 2: 3.33 / 0.00 / 30.00; 3: 3.33 / 0.00 / 30.00; 4: 3.34 / 0.00 / 30.00

Bill: subtotal 600.00, discount 10.00, discountable_subtotal 100.00, tax 0.00, service charge 0.00, rounding 0.00, **grand total 590.00**.

### G7

Discount larger than the pool: pizza 100 (restricted) + pasta 50 + soup 30, typed discount 120 -> capped at the pool 80 (the output 'discount' is 80).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":50,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]},{"key":3,"price":30,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":120,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.00 / 118.00; 2: 50.00 / 0.00 / 0.00; 3: 30.00 / 0.00 / 0.00

Bill: subtotal 180.00, discount 80.00, discountable_subtotal 80.00, tax 18.00, service charge 0.00, rounding 0.00, **grand total 118.00**.

### G8

Points only, nothing restricted: loyalty_discount 40 over 100 + 60 (spread pro rata before tax). Output has loyalty_discount but NO discountable_subtotal; 'discount' stays the typed part (0).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]},{"key":2,"price":60,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":0,"loyalty_discount":40,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 25.00 / 13.50 / 88.50; 2: 15.00 / 8.10 / 53.10

Bill: subtotal 160.00, discount 0.00, loyalty_discount 40.00, tax 21.60, service charge 0.00, rounding 0.00, **grand total 141.60**.

### G9

Typed 20 + points 80 on a pool of 100 (pizza restricted 100, pasta 100): both fit, the pasta is free, pizza keeps its tax.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":20,"loyalty_discount":80,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.00 / 118.00; 2: 100.00 / 0.00 / 0.00

Bill: subtotal 200.00, discount 20.00, loyalty_discount 80.00, discountable_subtotal 100.00, tax 18.00, service charge 0.00, rounding 0.00, **grand total 118.00**.

### G10

Typed 60 + points 40 on a pool of 80: the typed part first (60), the points take what is left of the pool (20). Total 100.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[],"no_disc":true},{"key":2,"price":50,"qty":1,"inclusive":false,"comps":[]},{"key":3,"price":30,"qty":1,"inclusive":false,"comps":[]}],"discount":60,"loyalty_discount":40,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 0.00 / 100.00; 2: 50.00 / 0.00 / 0.00; 3: 30.00 / 0.00 / 0.00

Bill: subtotal 180.00, discount 60.00, loyalty_discount 20.00, discountable_subtotal 80.00, tax 0.00, service charge 0.00, rounding 0.00, **grand total 100.00**.

### G11

Typed 150 on a pool of 100 with points 40 on top: the typed discount is cut to the pool (100), the points get 0 (nothing left). Because points were asked for, the output carries 'loyalty_discount': 0.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":150,"loyalty_discount":40,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.00 / 118.00; 2: 100.00 / 0.00 / 0.00

Bill: subtotal 200.00, discount 100.00, loyalty_discount 0.00, discountable_subtotal 100.00, tax 18.00, service charge 0.00, rounding 0.00, **grand total 118.00**.

### G12

Service charge 5% (taxable) with a restricted line and a discount: the service charge is computed on the discounted value of each line (the restricted line on its full price).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":100,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":20,"sc_percent":5,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 18.90 / 123.90; 2: 20.00 / 15.12 / 99.12

Bill: subtotal 200.00, discount 20.00, discountable_subtotal 100.00, tax 34.02, service charge 9.00, rounding 0.00, **grand total 223.02**.

### G13

Compound tax + nearest 0.05 rounding + restricted inclusive line: a larger mixed bill.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":259.27,"qty":2,"inclusive":true,"comps":[{"name":"A","rate":5,"compound":true},{"name":"B","rate":9,"compound":false}],"no_disc":true},{"key":2,"price":516.11,"qty":2.361,"inclusive":true,"comps":[{"name":"A","rate":5,"compound":true},{"name":"B","rate":9,"compound":false}]},{"key":3,"price":629.95,"qty":3,"inclusive":false,"comps":[]},{"key":4,"price":859.53,"qty":1,"inclusive":false,"comps":[{"name":"CGST","rate":9,"compound":false},{"name":"SGST","rate":9,"compound":false}]}],"discount":333.33,"sc_percent":0,"sc_taxable":true,"rounding":"nearest_0_05"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 63.68 / 518.54; 2: 102.36 / 137.08 / 1116.18; 3: 158.76 / 0.00 / 1731.09; 4: 72.21 / 141.72 / 929.04

Bill: subtotal 4486.46, discount 333.33, discountable_subtotal 3967.92, tax 342.48, service charge 0.00, rounding 0.00, **grand total 4294.85**.

### G14

Senior / PWD share ignores the flag (statutory): a restricted line still gets the senior discount (20% of its share).

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":100,"qty":1,"inclusive":false,"comps":[],"no_disc":true}],"discount":0,"senior":{"share":1,"rate":20},"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 0.00 / 80.00

Bill: subtotal 100.00, discount 0.00, discountable_subtotal 0.00, tax 0.00, service charge 0.00, rounding 0.00, **grand total 80.00**.

### G15

Many small lines: nine lines of 0.01 (one of 9.99) + a restricted 400, typed discount 0.07. Pro rata gives every 0.01 line 0.00, so the largest ELIGIBLE line (9.99) takes the whole 0.07; the restricted 400 gets 0; the parts add up exactly.

Input (`app.calc_bill`):

```json
{"lines":[{"key":1,"price":400,"qty":1,"inclusive":false,"comps":[],"no_disc":true},{"key":2,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":3,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":4,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":5,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":6,"price":9.99,"qty":1,"inclusive":false,"comps":[]},{"key":7,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":8,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":9,"price":0.01,"qty":1,"inclusive":false,"comps":[]},{"key":10,"price":0.01,"qty":1,"inclusive":false,"comps":[]}],"discount":0.07,"sc_percent":0,"sc_taxable":true,"rounding":"none"}
```

Per line (`key`: discount / tax / total): 1: 0.00 / 0.00 / 400.00; 2: 0.00 / 0.00 / 0.01; 3: 0.00 / 0.00 / 0.01; 4: 0.00 / 0.00 / 0.01; 5: 0.00 / 0.00 / 0.01; 6: 0.07 / 0.00 / 9.92; 7: 0.00 / 0.00 / 0.01; 8: 0.00 / 0.00 / 0.01; 9: 0.00 / 0.00 / 0.01; 10: 0.00 / 0.00 / 0.01

Bill: subtotal 410.07, discount 0.07, discountable_subtotal 10.07, tax 0.00, service charge 0.00, rounding 0.00, **grand total 410.00**.

## Not calc_bill (for the app's other tests)

- A complimentary / staff-meal bill sets `calc_params.comp_all`; `app.recalc_order` then does not send `no_disc` at all, so the whole bill comes off (the flag stays on the line for the record).
- `create_order` with a typed discount above the pool but not above the whole bill **cuts** it to the pool (no error); above the whole bill it is refused with the old message.
  `adjust_order` refuses with "The discount can be at most <pool> (some items on this bill cannot be discounted)." (the pool is printed with two decimals, for example `100.00`).
- Cash rounding is shown by G2: 212.40 -> 212 (nearest 1), rounding -0.40. The test restaurant (India preset) rounds to the nearest 1, so its stored bills show grand total 212.
- Redeeming points on a bill (`redeem_points_discount`, 145) sets `calc_params.loyalty_discount` = points x point value and `loyalty_points`; the order shows one `order_discounts` row of type
  `loyalty_points` (value = points, amount = money). Worked bill (database test 5.10): pasta 100 + restricted pizza 100, 30 points (point value 1): discount 30 on the pasta only, tax 12.60 + 18.00,
  total 200.60 -> 201 after rounding.
