-- 182: the module is called "Reports" (it holds POS reports, Purchase and inventory reports and other modules' reports).
update public.modules set name = 'Reports',
  description = 'POS reports, plus reports for each other module the client has (Purchase and inventory, Loyalty).'
 where key = 'reports_mis';
