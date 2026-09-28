export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      agent_actions: {
        Row: {
          action_type: string
          applied_at: string | null
          created_at: string
          entity_id: string | null
          entity_type: string
          id: string
          proposed_change: Json
          rationale: string | null
          restaurant_id: string
          review_note: string | null
          reviewed_at: string | null
          reviewed_by: string | null
          session_id: string
          status: string
        }
        Insert: {
          action_type: string
          applied_at?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type: string
          id?: string
          proposed_change: Json
          rationale?: string | null
          restaurant_id: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          session_id: string
          status?: string
        }
        Update: {
          action_type?: string
          applied_at?: string | null
          created_at?: string
          entity_id?: string | null
          entity_type?: string
          id?: string
          proposed_change?: Json
          rationale?: string | null
          restaurant_id?: string
          review_note?: string | null
          reviewed_at?: string | null
          reviewed_by?: string | null
          session_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_actions_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_actions_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_actions_reviewed_by_fkey"
            columns: ["reviewed_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "agent_actions_reviewed_by_same_rest"
            columns: ["restaurant_id", "reviewed_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "agent_actions_reviewed_by_same_rest"
            columns: ["restaurant_id", "reviewed_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["restaurant_id", "user_id"]
          },
          {
            foreignKeyName: "agent_actions_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "agent_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_actions_session_id_same_rest"
            columns: ["restaurant_id", "session_id"]
            isOneToOne: false
            referencedRelation: "agent_sessions"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      agent_messages: {
        Row: {
          content: string
          created_at: string
          executed_query: string | null
          id: string
          input_tokens: number | null
          latency_ms: number | null
          output_tokens: number | null
          restaurant_id: string
          role: string
          rows_returned: number | null
          session_id: string
        }
        Insert: {
          content: string
          created_at?: string
          executed_query?: string | null
          id?: string
          input_tokens?: number | null
          latency_ms?: number | null
          output_tokens?: number | null
          restaurant_id: string
          role: string
          rows_returned?: number | null
          session_id: string
        }
        Update: {
          content?: string
          created_at?: string
          executed_query?: string | null
          id?: string
          input_tokens?: number | null
          latency_ms?: number | null
          output_tokens?: number | null
          restaurant_id?: string
          role?: string
          rows_returned?: number | null
          session_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_messages_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_messages_session_id_fkey"
            columns: ["session_id"]
            isOneToOne: false
            referencedRelation: "agent_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_messages_session_id_same_rest"
            columns: ["restaurant_id", "session_id"]
            isOneToOne: false
            referencedRelation: "agent_sessions"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      agent_sessions: {
        Row: {
          branch_id: string | null
          channel: string
          created_at: string
          ended_at: string | null
          id: string
          job: string
          restaurant_id: string
          started_at: string
          user_id: string
        }
        Insert: {
          branch_id?: string | null
          channel?: string
          created_at?: string
          ended_at?: string | null
          id?: string
          job: string
          restaurant_id: string
          started_at?: string
          user_id: string
        }
        Update: {
          branch_id?: string | null
          channel?: string
          created_at?: string
          ended_at?: string | null
          id?: string
          job?: string
          restaurant_id?: string
          started_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_sessions_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_sessions_branch_id_same_rest"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "agent_sessions_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "agent_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "agent_sessions_user_id_same_rest"
            columns: ["restaurant_id", "user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "agent_sessions_user_id_same_rest"
            columns: ["restaurant_id", "user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["restaurant_id", "user_id"]
          },
        ]
      }
      agent_settings: {
        Row: {
          ai_processing_consent_at: string | null
          ai_provider_name: string | null
          allow_analyst: boolean
          allow_back_office: boolean
          allow_forecasting: boolean
          created_at: string
          is_enabled: boolean
          monthly_question_cap: number
          monthly_spend_cap: number
          preferred_language: string
          restaurant_id: string
          updated_at: string
        }
        Insert: {
          ai_processing_consent_at?: string | null
          ai_provider_name?: string | null
          allow_analyst?: boolean
          allow_back_office?: boolean
          allow_forecasting?: boolean
          created_at?: string
          is_enabled?: boolean
          monthly_question_cap?: number
          monthly_spend_cap?: number
          preferred_language?: string
          restaurant_id: string
          updated_at?: string
        }
        Update: {
          ai_processing_consent_at?: string | null
          ai_provider_name?: string | null
          allow_analyst?: boolean
          allow_back_office?: boolean
          allow_forecasting?: boolean
          created_at?: string
          is_enabled?: boolean
          monthly_question_cap?: number
          monthly_spend_cap?: number
          preferred_language?: string
          restaurant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_settings_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: true
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      agent_usage: {
        Row: {
          currency_code: string
          estimated_cost: number
          id: string
          input_tokens: number
          output_tokens: number
          period_month: string
          questions_asked: number
          restaurant_id: string
          updated_at: string
        }
        Insert: {
          currency_code?: string
          estimated_cost?: number
          id?: string
          input_tokens?: number
          output_tokens?: number
          period_month: string
          questions_asked?: number
          restaurant_id: string
          updated_at?: string
        }
        Update: {
          currency_code?: string
          estimated_cost?: number
          id?: string
          input_tokens?: number
          output_tokens?: number
          period_month?: string
          questions_asked?: number
          restaurant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "agent_usage_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "agent_usage_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      approval_failures: {
        Row: {
          at: string
          id: number
          restaurant_id: string
          user_id: string
        }
        Insert: {
          at?: string
          id?: number
          restaurant_id: string
          user_id: string
        }
        Update: {
          at?: string
          id?: number
          restaurant_id?: string
          user_id?: string
        }
        Relationships: []
      }
      approvals: {
        Row: {
          approved_by: string
          created_at: string
          expires_at: string
          id: string
          permission_key: string
          requested_by: string
          restaurant_id: string
          used_at: string | null
        }
        Insert: {
          approved_by: string
          created_at?: string
          expires_at?: string
          id?: string
          permission_key: string
          requested_by: string
          restaurant_id: string
          used_at?: string | null
        }
        Update: {
          approved_by?: string
          created_at?: string
          expires_at?: string
          id?: string
          permission_key?: string
          requested_by?: string
          restaurant_id?: string
          used_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "approvals_permission_key_fkey"
            columns: ["permission_key"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "approvals_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      audit_logs: {
        Row: {
          action: string
          actor_type: string
          agent_session_id: string | null
          branch_id: string | null
          created_at: string
          device_id: string | null
          entity_id: string | null
          entity_type: string
          id: number
          ip_address: unknown
          new_value: Json | null
          old_value: Json | null
          restaurant_id: string
          user_id: string | null
        }
        Insert: {
          action: string
          actor_type?: string
          agent_session_id?: string | null
          branch_id?: string | null
          created_at?: string
          device_id?: string | null
          entity_id?: string | null
          entity_type: string
          id?: number
          ip_address?: unknown
          new_value?: Json | null
          old_value?: Json | null
          restaurant_id: string
          user_id?: string | null
        }
        Update: {
          action?: string
          actor_type?: string
          agent_session_id?: string | null
          branch_id?: string | null
          created_at?: string
          device_id?: string | null
          entity_id?: string | null
          entity_type?: string
          id?: number
          ip_address?: unknown
          new_value?: Json | null
          old_value?: Json | null
          restaurant_id?: string
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "audit_logs_agent_session_fk"
            columns: ["agent_session_id"]
            isOneToOne: false
            referencedRelation: "agent_sessions"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "audit_logs_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      branch_settings: {
        Row: {
          auto_print_kot: boolean
          branch_id: string
          cash_rounding_mode: string
          default_order_type: string
          receipt_footer: string | null
          receipt_header: string | null
          restaurant_id: string
          rounding_cash_only: boolean
          service_charge_default_on: boolean
          service_charge_label: string
          service_charge_percent: number
          service_charge_taxable: boolean
          updated_at: string
        }
        Insert: {
          auto_print_kot?: boolean
          branch_id: string
          cash_rounding_mode?: string
          default_order_type?: string
          receipt_footer?: string | null
          receipt_header?: string | null
          restaurant_id: string
          rounding_cash_only?: boolean
          service_charge_default_on?: boolean
          service_charge_label?: string
          service_charge_percent?: number
          service_charge_taxable?: boolean
          updated_at?: string
        }
        Update: {
          auto_print_kot?: boolean
          branch_id?: string
          cash_rounding_mode?: string
          default_order_type?: string
          receipt_footer?: string | null
          receipt_header?: string | null
          restaurant_id?: string
          rounding_cash_only?: boolean
          service_charge_default_on?: boolean
          service_charge_label?: string
          service_charge_percent?: number
          service_charge_taxable?: boolean
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "branch_settings_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: true
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_settings_branch_id_same_rest"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "branch_settings_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      branches: {
        Row: {
          address_line1: string | null
          address_line2: string | null
          city: string | null
          code: string
          country_code: string
          created_at: string
          deleted_at: string | null
          id: string
          is_active: boolean
          name: string
          phone: string | null
          postal_code: string | null
          restaurant_id: string
          state_or_region: string | null
          timezone: string
          updated_at: string
        }
        Insert: {
          address_line1?: string | null
          address_line2?: string | null
          city?: string | null
          code: string
          country_code: string
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name: string
          phone?: string | null
          postal_code?: string | null
          restaurant_id: string
          state_or_region?: string | null
          timezone: string
          updated_at?: string
        }
        Update: {
          address_line1?: string | null
          address_line2?: string | null
          city?: string | null
          code?: string
          country_code?: string
          created_at?: string
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          name?: string
          phone?: string | null
          postal_code?: string | null
          restaurant_id?: string
          state_or_region?: string | null
          timezone?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "branches_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "branches_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      business_days: {
        Row: {
          branch_id: string
          business_date: string
          close_notes: string | null
          closed_at: string | null
          closed_by: string | null
          created_at: string
          id: string
          opened_at: string
          reopen_count: number
          restaurant_id: string
          status: string
          z_report: Json | null
        }
        Insert: {
          branch_id: string
          business_date: string
          close_notes?: string | null
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          opened_at?: string
          reopen_count?: number
          restaurant_id: string
          status?: string
          z_report?: Json | null
        }
        Update: {
          branch_id?: string
          business_date?: string
          close_notes?: string | null
          closed_at?: string | null
          closed_by?: string | null
          created_at?: string
          id?: string
          opened_at?: string
          reopen_count?: number
          restaurant_id?: string
          status?: string
          z_report?: Json | null
        }
        Relationships: [
          {
            foreignKeyName: "business_days_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "business_days_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      cash_movements: {
        Row: {
          amount: number
          created_at: string
          direction: string
          id: string
          reason: string
          recorded_by: string
          restaurant_id: string
          shift_id: string
        }
        Insert: {
          amount: number
          created_at?: string
          direction: string
          id?: string
          reason: string
          recorded_by: string
          restaurant_id: string
          shift_id: string
        }
        Update: {
          amount?: number
          created_at?: string
          direction?: string
          id?: string
          reason?: string
          recorded_by?: string
          restaurant_id?: string
          shift_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "cash_movements_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_movements_recorded_by_fkey"
            columns: ["recorded_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "cash_movements_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "cash_movements_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      categories: {
        Row: {
          created_at: string
          deleted_at: string | null
          display_order: number
          id: string
          image_url: string | null
          is_active: boolean
          name: string
          restaurant_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          image_url?: string | null
          is_active?: boolean
          name: string
          restaurant_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          deleted_at?: string | null
          display_order?: number
          id?: string
          image_url?: string | null
          is_active?: boolean
          name?: string
          restaurant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "categories_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      countries: {
        Row: {
          code: string
          compliance_note: string | null
          created_at: string
          default_currency: string
          default_timezone: string
          has_senior_discount: boolean
          invoice_title: string | null
          is_supported: boolean
          name: string
          requires_fiscal_certification: boolean
          tax_id_label: string | null
          tax_system_name: string
        }
        Insert: {
          code: string
          compliance_note?: string | null
          created_at?: string
          default_currency: string
          default_timezone: string
          has_senior_discount?: boolean
          invoice_title?: string | null
          is_supported?: boolean
          name: string
          requires_fiscal_certification?: boolean
          tax_id_label?: string | null
          tax_system_name: string
        }
        Update: {
          code?: string
          compliance_note?: string | null
          created_at?: string
          default_currency?: string
          default_timezone?: string
          has_senior_discount?: boolean
          invoice_title?: string | null
          is_supported?: boolean
          name?: string
          requires_fiscal_certification?: boolean
          tax_id_label?: string | null
          tax_system_name?: string
        }
        Relationships: []
      }
      credit_notes: {
        Row: {
          amount: number
          branch_id: string
          business_date: string
          created_at: string
          created_by: string
          id: string
          number: string
          order_id: string
          payment_method_id: string
          reason: string
          restaurant_id: string
          shift_id: string | null
          tax_amount: number
          taxes: Json
        }
        Insert: {
          amount: number
          branch_id: string
          business_date: string
          created_at?: string
          created_by: string
          id?: string
          number: string
          order_id: string
          payment_method_id: string
          reason: string
          restaurant_id: string
          shift_id?: string | null
          tax_amount?: number
          taxes?: Json
        }
        Update: {
          amount?: number
          branch_id?: string
          business_date?: string
          created_at?: string
          created_by?: string
          id?: string
          number?: string
          order_id?: string
          payment_method_id?: string
          reason?: string
          restaurant_id?: string
          shift_id?: string | null
          tax_amount?: number
          taxes?: Json
        }
        Relationships: [
          {
            foreignKeyName: "credit_notes_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "credit_notes_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_restaurant_id_order_id_fkey"
            columns: ["restaurant_id", "order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "credit_notes_restaurant_id_payment_method_id_fkey"
            columns: ["restaurant_id", "payment_method_id"]
            isOneToOne: false
            referencedRelation: "payment_methods"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      currencies: {
        Row: {
          code: string
          decimal_places: number
          name: string
          symbol: string
        }
        Insert: {
          code: string
          decimal_places?: number
          name: string
          symbol: string
        }
        Update: {
          code?: string
          decimal_places?: number
          name?: string
          symbol?: string
        }
        Relationships: []
      }
      customers: {
        Row: {
          consent_given_at: string | null
          created_at: string
          date_of_birth: string | null
          deleted_at: string | null
          email: string | null
          id: string
          marketing_consent: boolean
          name: string | null
          notes: string | null
          phone: string | null
          restaurant_id: string
          tax_registration_no: string | null
          updated_at: string
        }
        Insert: {
          consent_given_at?: string | null
          created_at?: string
          date_of_birth?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          marketing_consent?: boolean
          name?: string | null
          notes?: string | null
          phone?: string | null
          restaurant_id: string
          tax_registration_no?: string | null
          updated_at?: string
        }
        Update: {
          consent_given_at?: string | null
          created_at?: string
          date_of_birth?: string | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          marketing_consent?: boolean
          name?: string | null
          notes?: string | null
          phone?: string | null
          restaurant_id?: string
          tax_registration_no?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "customers_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      devices: {
        Row: {
          auth_user_id: string | null
          bill_fy: string | null
          bill_prefix: string | null
          branch_id: string
          created_at: string
          device_type: string
          id: string
          is_active: boolean
          last_seen_at: string | null
          name: string
          next_bill_seq: number
          restaurant_id: string
        }
        Insert: {
          auth_user_id?: string | null
          bill_fy?: string | null
          bill_prefix?: string | null
          branch_id: string
          created_at?: string
          device_type?: string
          id?: string
          is_active?: boolean
          last_seen_at?: string | null
          name: string
          next_bill_seq?: number
          restaurant_id: string
        }
        Update: {
          auth_user_id?: string | null
          bill_fy?: string | null
          bill_prefix?: string | null
          branch_id?: string
          created_at?: string
          device_type?: string
          id?: string
          is_active?: boolean
          last_seen_at?: string | null
          name?: string
          next_bill_seq?: number
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "devices_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "devices_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      dining_tables: {
        Row: {
          branch_id: string
          floor_id: string | null
          id: string
          is_active: boolean
          restaurant_id: string
          seats: number
          status: string
          table_number: string
          updated_at: string
        }
        Insert: {
          branch_id: string
          floor_id?: string | null
          id?: string
          is_active?: boolean
          restaurant_id: string
          seats?: number
          status?: string
          table_number: string
          updated_at?: string
        }
        Update: {
          branch_id?: string
          floor_id?: string | null
          id?: string
          is_active?: boolean
          restaurant_id?: string
          seats?: number
          status?: string
          table_number?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "dining_tables_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dining_tables_branch_id_same_rest"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "dining_tables_floor_id_fkey"
            columns: ["floor_id"]
            isOneToOne: false
            referencedRelation: "floors"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dining_tables_floor_id_same_rest"
            columns: ["restaurant_id", "floor_id"]
            isOneToOne: false
            referencedRelation: "floors"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "dining_tables_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      floors: {
        Row: {
          branch_id: string
          display_order: number
          id: string
          name: string
          restaurant_id: string
        }
        Insert: {
          branch_id: string
          display_order?: number
          id?: string
          name: string
          restaurant_id: string
        }
        Update: {
          branch_id?: string
          display_order?: number
          id?: string
          name?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "floors_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "floors_branch_id_same_rest"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "floors_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      kitchen_ticket_items: {
        Row: {
          id: string
          kitchen_ticket_id: string
          note: string | null
          order_item_id: string
          product_name: string
          quantity: number
          restaurant_id: string
          status: string
        }
        Insert: {
          id?: string
          kitchen_ticket_id: string
          note?: string | null
          order_item_id: string
          product_name: string
          quantity: number
          restaurant_id: string
          status?: string
        }
        Update: {
          id?: string
          kitchen_ticket_id?: string
          note?: string | null
          order_item_id?: string
          product_name?: string
          quantity?: number
          restaurant_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "kitchen_ticket_items_kitchen_ticket_id_fkey"
            columns: ["kitchen_ticket_id"]
            isOneToOne: false
            referencedRelation: "kitchen_tickets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kitchen_ticket_items_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kitchen_ticket_items_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      kitchen_tickets: {
        Row: {
          branch_id: string
          client_created_at: string
          created_at: string
          id: string
          order_id: string
          printed_at: string | null
          ready_at: string | null
          restaurant_id: string
          started_at: string | null
          station: string | null
          status: string
          synced_at: string | null
          ticket_number: string
        }
        Insert: {
          branch_id: string
          client_created_at: string
          created_at?: string
          id: string
          order_id: string
          printed_at?: string | null
          ready_at?: string | null
          restaurant_id: string
          started_at?: string | null
          station?: string | null
          status?: string
          synced_at?: string | null
          ticket_number: string
        }
        Update: {
          branch_id?: string
          client_created_at?: string
          created_at?: string
          id?: string
          order_id?: string
          printed_at?: string | null
          ready_at?: string | null
          restaurant_id?: string
          started_at?: string | null
          station?: string | null
          status?: string
          synced_at?: string | null
          ticket_number?: string
        }
        Relationships: [
          {
            foreignKeyName: "kitchen_tickets_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kitchen_tickets_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "kitchen_tickets_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      modifier_groups: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          is_required: boolean
          max_select: number
          min_select: number
          name: string
          restaurant_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          is_required?: boolean
          max_select?: number
          min_select?: number
          name: string
          restaurant_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          is_required?: boolean
          max_select?: number
          min_select?: number
          name?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "modifier_groups_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      modifier_items: {
        Row: {
          display_order: number
          id: string
          is_active: boolean
          modifier_group_id: string
          name: string
          price_delta: number
          restaurant_id: string
        }
        Insert: {
          display_order?: number
          id?: string
          is_active?: boolean
          modifier_group_id: string
          name: string
          price_delta?: number
          restaurant_id: string
        }
        Update: {
          display_order?: number
          id?: string
          is_active?: boolean
          modifier_group_id?: string
          name?: string
          price_delta?: number
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "modifier_items_modifier_group_id_fkey"
            columns: ["modifier_group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "modifier_items_modifier_group_id_same_rest"
            columns: ["restaurant_id", "modifier_group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "modifier_items_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      order_discounts: {
        Row: {
          amount: number
          approved_by: string
          created_at: string
          discount_type: string
          id: string
          order_id: string
          reason: string | null
          restaurant_id: string
          value: number
        }
        Insert: {
          amount: number
          approved_by: string
          created_at?: string
          discount_type: string
          id?: string
          order_id: string
          reason?: string | null
          restaurant_id: string
          value: number
        }
        Update: {
          amount?: number
          approved_by?: string
          created_at?: string
          discount_type?: string
          id?: string
          order_id?: string
          reason?: string | null
          restaurant_id?: string
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_discounts_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_discounts_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "order_discounts_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_discounts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      order_item_modifiers: {
        Row: {
          id: string
          modifier_item_id: string | null
          name: string
          order_item_id: string
          price_delta: number
          restaurant_id: string
        }
        Insert: {
          id?: string
          modifier_item_id?: string | null
          name: string
          order_item_id: string
          price_delta?: number
          restaurant_id: string
        }
        Update: {
          id?: string
          modifier_item_id?: string | null
          name?: string
          order_item_id?: string
          price_delta?: number
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "order_item_modifiers_modifier_item_id_fkey"
            columns: ["modifier_item_id"]
            isOneToOne: false
            referencedRelation: "modifier_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_item_modifiers_modifier_item_id_same_rest"
            columns: ["restaurant_id", "modifier_item_id"]
            isOneToOne: false
            referencedRelation: "modifier_items"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "order_item_modifiers_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_item_modifiers_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      order_item_taxes: {
        Row: {
          component_name: string
          id: string
          order_id: string
          order_item_id: string
          rate: number
          restaurant_id: string
          tax_amount: number
          taxable_amount: number
        }
        Insert: {
          component_name: string
          id?: string
          order_id: string
          order_item_id: string
          rate: number
          restaurant_id: string
          tax_amount: number
          taxable_amount: number
        }
        Update: {
          component_name?: string
          id?: string
          order_id?: string
          order_item_id?: string
          rate?: number
          restaurant_id?: string
          tax_amount?: number
          taxable_amount?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_item_taxes_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_item_taxes_order_item_id_fkey"
            columns: ["order_item_id"]
            isOneToOne: false
            referencedRelation: "order_items"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_item_taxes_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      order_items: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          cancelled_qty: number
          created_at: string
          id: string
          is_price_inclusive: boolean
          kitchen_note: string | null
          line_discount: number
          line_subtotal: number
          line_tax: number
          line_total: number
          modifier_total: number
          net_amount: number
          options_text: string | null
          order_id: string
          product_id: string
          product_name: string
          quantity: number
          restaurant_id: string
          service_charge: number
          tax_comps: Json | null
          tax_included: number
          unit_price: number
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          cancelled_qty?: number
          created_at?: string
          id: string
          is_price_inclusive?: boolean
          kitchen_note?: string | null
          line_discount?: number
          line_subtotal: number
          line_tax?: number
          line_total: number
          modifier_total?: number
          net_amount?: number
          options_text?: string | null
          order_id: string
          product_id: string
          product_name: string
          quantity: number
          restaurant_id: string
          service_charge?: number
          tax_comps?: Json | null
          tax_included?: number
          unit_price: number
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          cancelled_qty?: number
          created_at?: string
          id?: string
          is_price_inclusive?: boolean
          kitchen_note?: string | null
          line_discount?: number
          line_subtotal?: number
          line_tax?: number
          line_total?: number
          modifier_total?: number
          net_amount?: number
          options_text?: string | null
          order_id?: string
          product_id?: string
          product_name?: string
          quantity?: number
          restaurant_id?: string
          service_charge?: number
          tax_comps?: Json | null
          tax_included?: number
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "order_items_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "order_items_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "order_items_product_id_same_rest"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "order_items_product_id_same_rest"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "order_items_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      orders: {
        Row: {
          bill_number: string
          branch_id: string
          business_date: string | null
          buyer_gstin: string | null
          buyer_name: string | null
          calc_params: Json | null
          cashier_id: string
          client_created_at: string
          created_at: string
          currency_code: string
          customer_id: string | null
          device_id: string | null
          dining_table_id: string | null
          discount_total: number
          exempt_sales: number
          grand_total: number
          id: string
          merged_into: string | null
          order_type: string
          paid_total: number
          payment_status: string
          place_of_supply: string | null
          restaurant_id: string
          rounding_adjustment: number
          senior_details: Json | null
          service_charge: number
          shift_id: string | null
          status: string
          subtotal: number
          synced_at: string | null
          tax_exempt_amount: number
          tax_included: number
          tax_total: number
          updated_at: string
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
          waiter_id: string | null
        }
        Insert: {
          bill_number: string
          branch_id: string
          business_date?: string | null
          buyer_gstin?: string | null
          buyer_name?: string | null
          calc_params?: Json | null
          cashier_id: string
          client_created_at: string
          created_at?: string
          currency_code: string
          customer_id?: string | null
          device_id?: string | null
          dining_table_id?: string | null
          discount_total?: number
          exempt_sales?: number
          grand_total?: number
          id: string
          merged_into?: string | null
          order_type: string
          paid_total?: number
          payment_status?: string
          place_of_supply?: string | null
          restaurant_id: string
          rounding_adjustment?: number
          senior_details?: Json | null
          service_charge?: number
          shift_id?: string | null
          status?: string
          subtotal?: number
          synced_at?: string | null
          tax_exempt_amount?: number
          tax_included?: number
          tax_total?: number
          updated_at?: string
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
          waiter_id?: string | null
        }
        Update: {
          bill_number?: string
          branch_id?: string
          business_date?: string | null
          buyer_gstin?: string | null
          buyer_name?: string | null
          calc_params?: Json | null
          cashier_id?: string
          client_created_at?: string
          created_at?: string
          currency_code?: string
          customer_id?: string | null
          device_id?: string | null
          dining_table_id?: string | null
          discount_total?: number
          exempt_sales?: number
          grand_total?: number
          id?: string
          merged_into?: string | null
          order_type?: string
          paid_total?: number
          payment_status?: string
          place_of_supply?: string | null
          restaurant_id?: string
          rounding_adjustment?: number
          senior_details?: Json | null
          service_charge?: number
          shift_id?: string | null
          status?: string
          subtotal?: number
          synced_at?: string | null
          tax_exempt_amount?: number
          tax_included?: number
          tax_total?: number
          updated_at?: string
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
          waiter_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "orders_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_business_day_fk"
            columns: ["branch_id", "business_date"]
            isOneToOne: false
            referencedRelation: "business_days"
            referencedColumns: ["branch_id", "business_date"]
          },
          {
            foreignKeyName: "orders_cashier_id_fkey"
            columns: ["cashier_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_cashier_id_fkey"
            columns: ["cashier_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "orders_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_customer_id_same_rest"
            columns: ["restaurant_id", "customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "orders_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_dining_table_id_fkey"
            columns: ["dining_table_id"]
            isOneToOne: false
            referencedRelation: "dining_tables"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_dining_table_id_same_rest"
            columns: ["restaurant_id", "dining_table_id"]
            isOneToOne: false
            referencedRelation: "dining_tables"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "orders_merged_into_fkey"
            columns: ["merged_into"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_shift_fk"
            columns: ["shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_voided_by_fkey"
            columns: ["voided_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_voided_by_fkey"
            columns: ["voided_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "orders_waiter_id_fkey"
            columns: ["waiter_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_waiter_id_fkey"
            columns: ["waiter_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      payment_methods: {
        Row: {
          affects_cash_drawer: boolean
          ask_reference: boolean
          collection_mode: string
          display_order: number
          gateway_provider: string | null
          id: string
          is_active: boolean
          kind: string
          name: string
          restaurant_id: string
          upi_id: string | null
        }
        Insert: {
          affects_cash_drawer?: boolean
          ask_reference?: boolean
          collection_mode?: string
          display_order?: number
          gateway_provider?: string | null
          id?: string
          is_active?: boolean
          kind: string
          name: string
          restaurant_id: string
          upi_id?: string | null
        }
        Update: {
          affects_cash_drawer?: boolean
          ask_reference?: boolean
          collection_mode?: string
          display_order?: number
          gateway_provider?: string | null
          id?: string
          is_active?: boolean
          kind?: string
          name?: string
          restaurant_id?: string
          upi_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_methods_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount: number
          change_amount: number
          client_created_at: string
          created_at: string
          currency_code: string
          gateway_name: string | null
          id: string
          order_id: string
          payment_method_id: string
          received_by: string
          reference_no: string | null
          restaurant_id: string
          rounding_adjustment: number
          shift_id: string | null
          status: string
          synced_at: string | null
          tendered_amount: number | null
        }
        Insert: {
          amount: number
          change_amount?: number
          client_created_at: string
          created_at?: string
          currency_code: string
          gateway_name?: string | null
          id: string
          order_id: string
          payment_method_id: string
          received_by: string
          reference_no?: string | null
          restaurant_id: string
          rounding_adjustment?: number
          shift_id?: string | null
          status?: string
          synced_at?: string | null
          tendered_amount?: number | null
        }
        Update: {
          amount?: number
          change_amount?: number
          client_created_at?: string
          created_at?: string
          currency_code?: string
          gateway_name?: string | null
          id?: string
          order_id?: string
          payment_method_id?: string
          received_by?: string
          reference_no?: string | null
          restaurant_id?: string
          rounding_adjustment?: number
          shift_id?: string | null
          status?: string
          synced_at?: string | null
          tendered_amount?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "payments_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "payments_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_payment_method_id_fkey"
            columns: ["payment_method_id"]
            isOneToOne: false
            referencedRelation: "payment_methods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_payment_method_id_same_rest"
            columns: ["restaurant_id", "payment_method_id"]
            isOneToOne: false
            referencedRelation: "payment_methods"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "payments_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "payments_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      permissions: {
        Row: {
          description: string
          is_sensitive: boolean
          key: string
        }
        Insert: {
          description: string
          is_sensitive?: boolean
          key: string
        }
        Update: {
          description?: string
          is_sensitive?: boolean
          key?: string
        }
        Relationships: []
      }
      pin_attempts: {
        Row: {
          at: string
          device_id: string
          id: number
          ok: boolean
        }
        Insert: {
          at?: string
          device_id: string
          id?: never
          ok: boolean
        }
        Update: {
          at?: string
          device_id?: string
          id?: never
          ok?: boolean
        }
        Relationships: [
          {
            foreignKeyName: "pin_attempts_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
        ]
      }
      pin_sessions: {
        Row: {
          device_id: string
          expires_at: string
          last_activity_at: string
          restaurant_id: string
          started_at: string
          user_id: string
        }
        Insert: {
          device_id: string
          expires_at: string
          last_activity_at?: string
          restaurant_id: string
          started_at?: string
          user_id: string
        }
        Update: {
          device_id?: string
          expires_at?: string
          last_activity_at?: string
          restaurant_id?: string
          started_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pin_sessions_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: true
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pin_sessions_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pin_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pin_sessions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      printers: {
        Row: {
          address: string | null
          branch_id: string
          connection: string
          id: string
          is_active: boolean
          name: string
          paper_width_mm: number
          purpose: string
          restaurant_id: string
          station: string | null
        }
        Insert: {
          address?: string | null
          branch_id: string
          connection: string
          id?: string
          is_active?: boolean
          name: string
          paper_width_mm?: number
          purpose: string
          restaurant_id: string
          station?: string | null
        }
        Update: {
          address?: string | null
          branch_id?: string
          connection?: string
          id?: string
          is_active?: boolean
          name?: string
          paper_width_mm?: number
          purpose?: string
          restaurant_id?: string
          station?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "printers_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "printers_branch_id_same_rest"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "printers_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      product_modifier_groups: {
        Row: {
          modifier_group_id: string
          product_id: string
          restaurant_id: string
        }
        Insert: {
          modifier_group_id: string
          product_id: string
          restaurant_id: string
        }
        Update: {
          modifier_group_id?: string
          product_id?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "product_modifier_groups_modifier_group_id_fkey"
            columns: ["modifier_group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_modifier_groups_modifier_group_id_same_rest"
            columns: ["restaurant_id", "modifier_group_id"]
            isOneToOne: false
            referencedRelation: "modifier_groups"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "product_modifier_groups_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_modifier_groups_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "product_modifier_groups_product_id_same_rest"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "product_modifier_groups_product_id_same_rest"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "product_modifier_groups_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      products: {
        Row: {
          barcode: string | null
          category_id: string
          cost_price: number | null
          created_at: string
          deleted_at: string | null
          description: string | null
          display_order: number
          hsn_code: string | null
          id: string
          image_url: string | null
          is_available: boolean
          is_veg: boolean | null
          kitchen_station: string | null
          name: string
          price: number
          restaurant_id: string
          short_name: string | null
          sku: string | null
          tax_group_id: string
          updated_at: string
        }
        Insert: {
          barcode?: string | null
          category_id: string
          cost_price?: number | null
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          display_order?: number
          hsn_code?: string | null
          id?: string
          image_url?: string | null
          is_available?: boolean
          is_veg?: boolean | null
          kitchen_station?: string | null
          name: string
          price: number
          restaurant_id: string
          short_name?: string | null
          sku?: string | null
          tax_group_id: string
          updated_at?: string
        }
        Update: {
          barcode?: string | null
          category_id?: string
          cost_price?: number | null
          created_at?: string
          deleted_at?: string | null
          description?: string | null
          display_order?: number
          hsn_code?: string | null
          id?: string
          image_url?: string | null
          is_available?: boolean
          is_veg?: boolean | null
          kitchen_station?: string | null
          name?: string
          price?: number
          restaurant_id?: string
          short_name?: string | null
          sku?: string | null
          tax_group_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "products_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_category_id_same_rest"
            columns: ["restaurant_id", "category_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "products_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_tax_group_id_fkey"
            columns: ["tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_tax_group_id_same_rest"
            columns: ["restaurant_id", "tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      refunds: {
        Row: {
          amount: number
          approved_by: string
          client_created_at: string
          created_at: string
          credit_note_id: string | null
          id: string
          order_id: string
          payment_id: string | null
          payment_method_id: string | null
          reason: string
          restaurant_id: string
          shift_id: string | null
          synced_at: string | null
        }
        Insert: {
          amount: number
          approved_by: string
          client_created_at: string
          created_at?: string
          credit_note_id?: string | null
          id: string
          order_id: string
          payment_id?: string | null
          payment_method_id?: string | null
          reason: string
          restaurant_id: string
          shift_id?: string | null
          synced_at?: string | null
        }
        Update: {
          amount?: number
          approved_by?: string
          client_created_at?: string
          created_at?: string
          credit_note_id?: string | null
          id?: string
          order_id?: string
          payment_id?: string | null
          payment_method_id?: string | null
          reason?: string
          restaurant_id?: string
          shift_id?: string | null
          synced_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "refunds_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_approved_by_fkey"
            columns: ["approved_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "refunds_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "refunds_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      restaurants: {
        Row: {
          contact_email: string | null
          contact_phone: string | null
          country_code: string
          created_at: string
          currency_code: string
          deleted_at: string | null
          fssai_no: string | null
          id: string
          legal_name: string
          logo_url: string | null
          sac_code: string | null
          subscription_status: string
          tax_registration_no: string | null
          timezone: string
          trading_name: string
          updated_at: string
        }
        Insert: {
          contact_email?: string | null
          contact_phone?: string | null
          country_code: string
          created_at?: string
          currency_code: string
          deleted_at?: string | null
          fssai_no?: string | null
          id?: string
          legal_name: string
          logo_url?: string | null
          sac_code?: string | null
          subscription_status?: string
          tax_registration_no?: string | null
          timezone: string
          trading_name: string
          updated_at?: string
        }
        Update: {
          contact_email?: string | null
          contact_phone?: string | null
          country_code?: string
          created_at?: string
          currency_code?: string
          deleted_at?: string | null
          fssai_no?: string | null
          id?: string
          legal_name?: string
          logo_url?: string | null
          sac_code?: string | null
          subscription_status?: string
          tax_registration_no?: string | null
          timezone?: string
          trading_name?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "restaurants_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "restaurants_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      role_permissions: {
        Row: {
          permission_key: string
          role_id: string
        }
        Insert: {
          permission_key: string
          role_id: string
        }
        Update: {
          permission_key?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_key_fkey"
            columns: ["permission_key"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["role_id"]
          },
        ]
      }
      roles: {
        Row: {
          created_at: string
          id: string
          is_system: boolean
          name: string
          restaurant_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_system?: boolean
          name: string
          restaurant_id: string
        }
        Update: {
          created_at?: string
          id?: string
          is_system?: boolean
          name?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "roles_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      shifts: {
        Row: {
          branch_id: string
          cash_variance: number | null
          closed_at: string | null
          closed_by: string | null
          counted_cash: number | null
          created_at: string
          device_id: string | null
          expected_cash: number | null
          id: string
          notes: string | null
          opened_at: string
          opened_by: string
          opening_float: number
          restaurant_id: string
          status: string
          synced_at: string | null
        }
        Insert: {
          branch_id: string
          cash_variance?: number | null
          closed_at?: string | null
          closed_by?: string | null
          counted_cash?: number | null
          created_at?: string
          device_id?: string | null
          expected_cash?: number | null
          id: string
          notes?: string | null
          opened_at: string
          opened_by: string
          opening_float?: number
          restaurant_id: string
          status?: string
          synced_at?: string | null
        }
        Update: {
          branch_id?: string
          cash_variance?: number | null
          closed_at?: string | null
          closed_by?: string | null
          counted_cash?: number | null
          created_at?: string
          device_id?: string | null
          expected_cash?: number | null
          id?: string
          notes?: string | null
          opened_at?: string
          opened_by?: string
          opening_float?: number
          restaurant_id?: string
          status?: string
          synced_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "shifts_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_closed_by_fkey"
            columns: ["closed_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_closed_by_fkey"
            columns: ["closed_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "shifts_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_opened_by_fkey"
            columns: ["opened_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shifts_opened_by_fkey"
            columns: ["opened_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "shifts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      staff_invites: {
        Row: {
          code_hash: string
          created_at: string
          created_by: string | null
          expires_at: string
          restaurant_id: string
          user_id: string
        }
        Insert: {
          code_hash: string
          created_at?: string
          created_by?: string | null
          expires_at: string
          restaurant_id: string
          user_id: string
        }
        Update: {
          code_hash?: string
          created_at?: string
          created_by?: string | null
          expires_at?: string
          restaurant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "staff_invites_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_invites_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "staff_invites_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_invites_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "staff_invites_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: true
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      sync_log: {
        Row: {
          device_id: string
          direction: string
          error_detail: string | null
          finished_at: string | null
          id: number
          records_failed: number
          records_ok: number
          records_sent: number
          restaurant_id: string
          started_at: string
        }
        Insert: {
          device_id: string
          direction: string
          error_detail?: string | null
          finished_at?: string | null
          id?: number
          records_failed?: number
          records_ok?: number
          records_sent?: number
          restaurant_id: string
          started_at: string
        }
        Update: {
          device_id?: string
          direction?: string
          error_detail?: string | null
          finished_at?: string | null
          id?: number
          records_failed?: number
          records_ok?: number
          records_sent?: number
          restaurant_id?: string
          started_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "sync_log_device_id_fkey"
            columns: ["device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sync_log_device_id_same_rest"
            columns: ["restaurant_id", "device_id"]
            isOneToOne: false
            referencedRelation: "devices"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "sync_log_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      tax_groups: {
        Row: {
          created_at: string
          id: string
          is_active: boolean
          is_price_inclusive: boolean
          name: string
          restaurant_id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          is_active?: boolean
          is_price_inclusive?: boolean
          name: string
          restaurant_id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          is_active?: boolean
          is_price_inclusive?: boolean
          name?: string
          restaurant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "tax_groups_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      tax_rate_components: {
        Row: {
          applies_when: string
          display_order: number
          id: string
          is_compound: boolean
          name: string
          rate: number
          restaurant_id: string
          tax_rate_id: string
        }
        Insert: {
          applies_when?: string
          display_order?: number
          id?: string
          is_compound?: boolean
          name: string
          rate: number
          restaurant_id: string
          tax_rate_id: string
        }
        Update: {
          applies_when?: string
          display_order?: number
          id?: string
          is_compound?: boolean
          name?: string
          rate?: number
          restaurant_id?: string
          tax_rate_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "tax_rate_components_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tax_rate_components_tax_rate_id_fkey"
            columns: ["tax_rate_id"]
            isOneToOne: false
            referencedRelation: "tax_rates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tax_rate_components_tax_rate_id_same_rest"
            columns: ["restaurant_id", "tax_rate_id"]
            isOneToOne: false
            referencedRelation: "tax_rates"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      tax_rates: {
        Row: {
          created_at: string
          id: string
          restaurant_id: string
          tax_group_id: string
          total_rate: number
          valid_from: string
          valid_to: string | null
        }
        Insert: {
          created_at?: string
          id?: string
          restaurant_id: string
          tax_group_id: string
          total_rate: number
          valid_from: string
          valid_to?: string | null
        }
        Update: {
          created_at?: string
          id?: string
          restaurant_id?: string
          tax_group_id?: string
          total_rate?: number
          valid_from?: string
          valid_to?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "tax_rates_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tax_rates_tax_group_id_fkey"
            columns: ["tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "tax_rates_tax_group_id_same_rest"
            columns: ["restaurant_id", "tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      user_branches: {
        Row: {
          branch_id: string
          restaurant_id: string
          user_id: string
        }
        Insert: {
          branch_id: string
          restaurant_id: string
          user_id: string
        }
        Update: {
          branch_id?: string
          restaurant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_branches_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_branches_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_branches_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "user_branches_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      users: {
        Row: {
          auth_user_id: string | null
          created_at: string
          deleted_at: string | null
          email: string | null
          employee_code: string
          full_name: string
          id: string
          is_active: boolean
          last_login_at: string | null
          must_change_password: boolean
          password_reset_hash: string | null
          phone: string | null
          pin_hash: string | null
          pin_set_at: string | null
          restaurant_id: string
          role_id: string
          updated_at: string
        }
        Insert: {
          auth_user_id?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          employee_code: string
          full_name: string
          id?: string
          is_active?: boolean
          last_login_at?: string | null
          must_change_password?: boolean
          password_reset_hash?: string | null
          phone?: string | null
          pin_hash?: string | null
          pin_set_at?: string | null
          restaurant_id: string
          role_id: string
          updated_at?: string
        }
        Update: {
          auth_user_id?: string | null
          created_at?: string
          deleted_at?: string | null
          email?: string | null
          employee_code?: string
          full_name?: string
          id?: string
          is_active?: boolean
          last_login_at?: string | null
          must_change_password?: boolean
          password_reset_hash?: string | null
          phone?: string | null
          pin_hash?: string | null
          pin_set_at?: string | null
          restaurant_id?: string
          role_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "users_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "users_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "users_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["role_id"]
          },
          {
            foreignKeyName: "users_role_id_same_rest"
            columns: ["restaurant_id", "role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
    }
    Views: {
      v_current_user: {
        Row: {
          country_code: string | null
          currency_code: string | null
          device_name: string | null
          email: string | null
          employee_code: string | null
          full_name: string | null
          must_change_password: boolean | null
          permissions: string[] | null
          restaurant_id: string | null
          role_id: string | null
          role_name: string | null
          timezone: string | null
          trading_name: string | null
          user_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "restaurants_country_code_fkey"
            columns: ["country_code"]
            isOneToOne: false
            referencedRelation: "countries"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "restaurants_currency_code_fkey"
            columns: ["currency_code"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "users_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      v_menu: {
        Row: {
          category_id: string | null
          category_name: string | null
          category_order: number | null
          display_order: number | null
          id: string | null
          is_available: boolean | null
          is_price_inclusive: boolean | null
          is_veg: boolean | null
          name: string | null
          price: number | null
          restaurant_id: string | null
          short_name: string | null
          tax_group_id: string | null
          tax_group_name: string | null
          tax_rate: number | null
        }
        Relationships: [
          {
            foreignKeyName: "products_category_id_fkey"
            columns: ["category_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_category_id_same_rest"
            columns: ["restaurant_id", "category_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "products_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_tax_group_id_fkey"
            columns: ["tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "products_tax_group_id_same_rest"
            columns: ["restaurant_id", "tax_group_id"]
            isOneToOne: false
            referencedRelation: "tax_groups"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
    }
    Functions: {
      add_order_items: {
        Args: { p_items: Json; p_order_id: string }
        Returns: Json
      }
      adjust_order: {
        Args: {
          p_discount_amount: number
          p_discount_reason?: string
          p_order_id: string
          p_service_charge?: boolean
        }
        Returns: Json
      }
      admin_reset_password: {
        Args: { p_new_password: string; p_user_id: string }
        Returns: undefined
      }
      approve_with_pin: {
        Args: { p_permission: string; p_pin: string }
        Returns: Json
      }
      cancel_invite: { Args: { p_user_id: string }; Returns: undefined }
      cancel_order_item: {
        Args: { p_order_item_id: string; p_qty: number; p_reason: string }
        Returns: Json
      }
      change_payment_method: {
        Args: { p_method_id: string; p_payment_id: string; p_reason: string }
        Returns: Json
      }
      claim_staff_invite: { Args: { p_code: string }; Returns: string }
      clear_pin_lockout: { Args: { p_device_id: string }; Returns: undefined }
      clear_staff_pin: { Args: { p_user_id: string }; Returns: undefined }
      close_day: { Args: { p_notes?: string }; Returns: Json }
      close_shift: {
        Args: { p_counted_cash: number; p_notes?: string }
        Returns: Json
      }
      create_order: {
        Args: {
          p_customer_id?: string
          p_discount_amount?: number
          p_discount_reason?: string
          p_items: Json
          p_order_type?: string
          p_payment_method_id?: string
          p_reference?: string
          p_senior?: Json
          p_service_charge?: boolean
          p_table_id?: string
          p_tendered?: number
        }
        Returns: Json
      }
      create_pin_staff: {
        Args: { p_full_name: string; p_phone?: string; p_role_id: string }
        Returns: Json
      }
      create_restaurant_with_owner: {
        Args: {
          p_branch_code?: string
          p_branch_name?: string
          p_country_code: string
          p_legal_name: string
          p_owner_name: string
          p_tax_registration_no?: string
          p_timezone?: string
          p_trading_name: string
        }
        Returns: string
      }
      create_tax_group: {
        Args: { p_name: string; p_total_rate: number }
        Returns: string
      }
      current_shift: { Args: never; Returns: Json }
      day_report: { Args: { p_day_id: string }; Returns: Json }
      day_status: { Args: never; Returns: Json }
      delete_role: { Args: { p_role_id: string }; Returns: undefined }
      gst_register: { Args: { p_from: string; p_to: string }; Returns: Json }
      invite_staff: {
        Args: {
          p_email: string
          p_full_name: string
          p_phone?: string
          p_role_id: string
        }
        Returns: Json
      }
      issue_credit_note: {
        Args: {
          p_amount: number
          p_method_id: string
          p_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      merge_orders: {
        Args: { p_source_id: string; p_target_id: string }
        Returns: Json
      }
      move_order_table: {
        Args: { p_order_id: string; p_table_id: string }
        Returns: Json
      }
      my_account_state: { Args: never; Returns: string }
      my_device_state: { Args: never; Returns: Json }
      open_shift: { Args: { p_opening_float?: number }; Returns: string }
      password_changed: { Args: never; Returns: undefined }
      pay_order: {
        Args: {
          p_amount?: number
          p_order_id: string
          p_payment_method_id: string
          p_reference?: string
          p_tendered?: number
        }
        Returns: Json
      }
      pin_lock: { Args: never; Returns: undefined }
      pin_touch: { Args: never; Returns: boolean }
      pin_unlock: { Args: { p_pin: string }; Returns: Json }
      quote_order: {
        Args: {
          p_discount_amount?: number
          p_items: Json
          p_senior?: Json
          p_service_charge?: boolean
        }
        Returns: Json
      }
      record_cash_movement: {
        Args: { p_amount: number; p_direction: string; p_reason: string }
        Returns: string
      }
      refund_order: {
        Args: { p_amount: number; p_order_id: string; p_reason: string }
        Returns: Json
      }
      regenerate_invite: { Args: { p_user_id: string }; Returns: Json }
      register_counter_device: {
        Args: { p_auth_user_id: string; p_name: string }
        Returns: string
      }
      remove_counter_device: {
        Args: { p_device_id: string }
        Returns: undefined
      }
      reopen_day: { Args: { p_reason: string }; Returns: Json }
      sales_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      save_payment_method: {
        Args: {
          p_ask_reference?: boolean
          p_id: string
          p_kind: string
          p_name: string
          p_upi_id?: string
        }
        Returns: string
      }
      save_role: {
        Args: { p_name: string; p_permissions: string[]; p_role_id: string }
        Returns: string
      }
      save_tax_group: {
        Args: { p_components: Json; p_group_id: string; p_name: string }
        Returns: string
      }
      set_bill_customer: {
        Args: { p_gstin: string; p_name: string; p_order_id: string }
        Returns: Json
      }
      set_kitchen_status: {
        Args: { p_status: string; p_ticket_id: string }
        Returns: undefined
      }
      set_prices_include_tax: {
        Args: { p_inclusive: boolean }
        Returns: undefined
      }
      set_staff_pin: {
        Args: { p_pin?: string; p_user_id: string }
        Returns: Json
      }
      set_tax_rate: {
        Args: { p_tax_group_id: string; p_total_rate: number }
        Returns: undefined
      }
      settlement_report: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      shift_report: { Args: { p_shift_id: string }; Returns: Json }
      split_order: {
        Args: { p_items: Json; p_order_id: string }
        Returns: Json
      }
      update_settings: { Args: { p_settings: Json }; Returns: undefined }
      update_staff: {
        Args: { p_is_active?: boolean; p_role_id?: string; p_user_id: string }
        Returns: undefined
      }
      void_order: {
        Args: { p_order_id: string; p_reason: string }
        Returns: Json
      }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
