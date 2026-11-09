-- Purchase tax per line and input tax credit.
-- A receipt line can carry a tax rate. When the restaurant has turned on "we claim input tax" AND the supplier has a tax number, the line's tax is
-- claimable: it stays out of the stock cost. Otherwise the tax is a real cost and goes into the stock cost (price paid including tax).
-- Receipt total is unchanged in meaning (goods + all tax + other charges). Applied live; this file is the record.
alter table public.purchase_settings add column if not exists claim_input_tax boolean not null default false;
alter table public.goods_receipt_lines add column if not exists tax_rate numeric(6,3) not null default 0 check (tax_rate between 0 and 100);
alter table public.goods_receipt_lines add column if not exists tax_amount numeric(14,2) not null default 0;
alter table public.goods_receipt_lines add column if not exists tax_claimable boolean not null default false;
alter table public.goods_receipts add column if not exists input_tax_claimable numeric(14,2) not null default 0;
-- public.set_input_tax_claim(boolean) (settings.manage), patches to public.receive_goods (per-line tax_rate in p_lines, v_eff stock cost,
-- v_ok claimable test), and tax columns added to report_receipts / report_supplier_purchases were applied through the Supabase migration
-- "purchase_tax_per_line_input_credit" (the SQL is in the migration history of the project).
