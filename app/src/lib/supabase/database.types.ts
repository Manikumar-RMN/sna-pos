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
    PostgrestVersion: "14.17"
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
      api_calls: {
        Row: {
          action: string
          at: string
          id: number
          key_id: string
        }
        Insert: {
          action: string
          at?: string
          id?: number
          key_id: string
        }
        Update: {
          action?: string
          at?: string
          id?: number
          key_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "api_calls_key_id_fkey"
            columns: ["key_id"]
            isOneToOne: false
            referencedRelation: "api_keys"
            referencedColumns: ["id"]
          },
        ]
      }
      api_keys: {
        Row: {
          created_at: string
          created_by: string | null
          id: string
          key_hash: string
          last_used_at: string | null
          name: string
          prefix: string
          restaurant_id: string
          revoked_at: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          id?: string
          key_hash: string
          last_used_at?: string | null
          name: string
          prefix: string
          restaurant_id: string
          revoked_at?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          id?: string
          key_hash?: string
          last_used_at?: string | null
          name?: string
          prefix?: string
          restaurant_id?: string
          revoked_at?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "api_keys_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "api_keys_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "api_keys_restaurant_id_fkey"
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
      branch_prices: {
        Row: {
          branch_id: string
          is_available: boolean | null
          price: number | null
          product_id: string
          restaurant_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          branch_id: string
          is_available?: boolean | null
          price?: number | null
          product_id: string
          restaurant_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          branch_id?: string
          is_available?: boolean | null
          price?: number | null
          product_id?: string
          restaurant_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "branch_prices_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_prices_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_prices_product_id_fkey"
            columns: ["product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_prices_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_prices_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "branch_prices_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      branch_settings: {
        Row: {
          auto_print_kot: boolean
          bill_format: Json
          branch_id: string
          cash_rounding_mode: string
          day_cutoff: string
          default_order_type: string
          packing_delivery: boolean
          packing_per: string
          packing_product_id: string | null
          packing_takeaway: boolean
          receipt_footer: string | null
          receipt_header: string | null
          restaurant_id: string
          rounding_cash_only: boolean
          service_charge_default_on: boolean
          service_charge_label: string
          service_charge_percent: number
          service_charge_taxable: boolean
          shifts_enabled: boolean
          token_numbers: string
          updated_at: string
        }
        Insert: {
          auto_print_kot?: boolean
          bill_format?: Json
          branch_id: string
          cash_rounding_mode?: string
          day_cutoff?: string
          default_order_type?: string
          packing_delivery?: boolean
          packing_per?: string
          packing_product_id?: string | null
          packing_takeaway?: boolean
          receipt_footer?: string | null
          receipt_header?: string | null
          restaurant_id: string
          rounding_cash_only?: boolean
          service_charge_default_on?: boolean
          service_charge_label?: string
          service_charge_percent?: number
          service_charge_taxable?: boolean
          shifts_enabled?: boolean
          token_numbers?: string
          updated_at?: string
        }
        Update: {
          auto_print_kot?: boolean
          bill_format?: Json
          branch_id?: string
          cash_rounding_mode?: string
          day_cutoff?: string
          default_order_type?: string
          packing_delivery?: boolean
          packing_per?: string
          packing_product_id?: string | null
          packing_takeaway?: boolean
          receipt_footer?: string | null
          receipt_header?: string | null
          restaurant_id?: string
          rounding_cash_only?: boolean
          service_charge_default_on?: boolean
          service_charge_label?: string
          service_charge_percent?: number
          service_charge_taxable?: boolean
          shifts_enabled?: boolean
          token_numbers?: string
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
            foreignKeyName: "branch_settings_packing_product_same_rest"
            columns: ["restaurant_id", "packing_product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "branch_settings_packing_product_same_rest"
            columns: ["restaurant_id", "packing_product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
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
          is_central_kitchen: boolean
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
          is_central_kitchen?: boolean
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
          is_central_kitchen?: boolean
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
          last_token: number
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
          last_token?: number
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
          last_token?: number
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
          parent_id: string | null
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
          parent_id?: string | null
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
          parent_id?: string | null
          restaurant_id?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "categories_parent_same_rest"
            columns: ["restaurant_id", "parent_id"]
            isOneToOne: false
            referencedRelation: "categories"
            referencedColumns: ["restaurant_id", "id"]
          },
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
          dial_code: string | null
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
          dial_code?: string | null
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
          dial_code?: string | null
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
          qr_token: string | null
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
          qr_token?: string | null
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
          qr_token?: string | null
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
      gift_card_ledger: {
        Row: {
          amount: number
          created_at: string
          created_by: string | null
          gift_card_id: string
          id: string
          kind: string
          order_id: string | null
          restaurant_id: string
        }
        Insert: {
          amount: number
          created_at?: string
          created_by?: string | null
          gift_card_id: string
          id?: string
          kind: string
          order_id?: string | null
          restaurant_id: string
        }
        Update: {
          amount?: number
          created_at?: string
          created_by?: string | null
          gift_card_id?: string
          id?: string
          kind?: string
          order_id?: string | null
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "gift_card_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "gift_card_ledger_gift_card_id_fkey"
            columns: ["gift_card_id"]
            isOneToOne: false
            referencedRelation: "gift_cards"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_ledger_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_card_ledger_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      gift_cards: {
        Row: {
          code: string
          created_at: string
          customer_id: string | null
          expires_on: string | null
          id: string
          issued_by: string | null
          restaurant_id: string
          sold_branch_id: string | null
          sold_method_id: string | null
          sold_shift_id: string | null
          value: number
        }
        Insert: {
          code: string
          created_at?: string
          customer_id?: string | null
          expires_on?: string | null
          id?: string
          issued_by?: string | null
          restaurant_id: string
          sold_branch_id?: string | null
          sold_method_id?: string | null
          sold_shift_id?: string | null
          value: number
        }
        Update: {
          code?: string
          created_at?: string
          customer_id?: string | null
          expires_on?: string | null
          id?: string
          issued_by?: string | null
          restaurant_id?: string
          sold_branch_id?: string | null
          sold_method_id?: string | null
          sold_shift_id?: string | null
          value?: number
        }
        Relationships: [
          {
            foreignKeyName: "gift_cards_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_issued_by_fkey"
            columns: ["issued_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "gift_cards_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_sold_branch_id_fkey"
            columns: ["sold_branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_sold_method_id_fkey"
            columns: ["sold_method_id"]
            isOneToOne: false
            referencedRelation: "payment_methods"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "gift_cards_sold_shift_id_fkey"
            columns: ["sold_shift_id"]
            isOneToOne: false
            referencedRelation: "shifts"
            referencedColumns: ["id"]
          },
        ]
      }
      goods_receipt_lines: {
        Row: {
          goods_receipt_id: string
          id: string
          ingredient_id: string
          line_total: number
          new_cost: number | null
          prev_cost: number | null
          qty: number
          restaurant_id: string
          unit_cost: number
        }
        Insert: {
          goods_receipt_id: string
          id?: string
          ingredient_id: string
          line_total: number
          new_cost?: number | null
          prev_cost?: number | null
          qty: number
          restaurant_id: string
          unit_cost: number
        }
        Update: {
          goods_receipt_id?: string
          id?: string
          ingredient_id?: string
          line_total?: number
          new_cost?: number | null
          prev_cost?: number | null
          qty?: number
          restaurant_id?: string
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "goods_receipt_lines_restaurant_id_goods_receipt_id_fkey"
            columns: ["restaurant_id", "goods_receipt_id"]
            isOneToOne: false
            referencedRelation: "goods_receipts"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "goods_receipt_lines_restaurant_id_ingredient_id_fkey"
            columns: ["restaurant_id", "ingredient_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      goods_receipts: {
        Row: {
          branch_id: string
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          client_ref: string | null
          created_at: string
          due_on: string | null
          id: string
          notes: string | null
          number: string
          other_charges: number
          paid_total: number
          payment_status: string
          purchase_order_id: string | null
          received_by: string
          received_on: string
          restaurant_id: string
          status: string
          subtotal: number
          supplier_bill_date: string | null
          supplier_bill_no: string | null
          supplier_id: string
          tax_amount: number
          total: number
        }
        Insert: {
          branch_id: string
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          client_ref?: string | null
          created_at?: string
          due_on?: string | null
          id?: string
          notes?: string | null
          number: string
          other_charges?: number
          paid_total?: number
          payment_status?: string
          purchase_order_id?: string | null
          received_by: string
          received_on: string
          restaurant_id: string
          status?: string
          subtotal?: number
          supplier_bill_date?: string | null
          supplier_bill_no?: string | null
          supplier_id: string
          tax_amount?: number
          total?: number
        }
        Update: {
          branch_id?: string
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          client_ref?: string | null
          created_at?: string
          due_on?: string | null
          id?: string
          notes?: string | null
          number?: string
          other_charges?: number
          paid_total?: number
          payment_status?: string
          purchase_order_id?: string | null
          received_by?: string
          received_on?: string
          restaurant_id?: string
          status?: string
          subtotal?: number
          supplier_bill_date?: string | null
          supplier_bill_no?: string | null
          supplier_id?: string
          tax_amount?: number
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "goods_receipts_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_receipts_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "goods_receipts_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_receipts_received_by_fkey"
            columns: ["received_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "goods_receipts_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "goods_receipts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "goods_receipts_restaurant_id_purchase_order_id_fkey"
            columns: ["restaurant_id", "purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "goods_receipts_restaurant_id_supplier_id_fkey"
            columns: ["restaurant_id", "supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      ingredients: {
        Row: {
          category: string | null
          cost_per_unit: number
          created_at: string
          id: string
          is_active: boolean
          name: string
          reorder_level: number
          restaurant_id: string
          unit: string
        }
        Insert: {
          category?: string | null
          cost_per_unit?: number
          created_at?: string
          id?: string
          is_active?: boolean
          name: string
          reorder_level?: number
          restaurant_id: string
          unit: string
        }
        Update: {
          category?: string | null
          cost_per_unit?: number
          created_at?: string
          id?: string
          is_active?: boolean
          name?: string
          reorder_level?: number
          restaurant_id?: string
          unit?: string
        }
        Relationships: [
          {
            foreignKeyName: "ingredients_restaurant_id_fkey"
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
          product_name_local: string | null
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
          product_name_local?: string | null
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
          product_name_local?: string | null
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
      loyalty_ledger: {
        Row: {
          created_at: string
          created_by: string | null
          customer_id: string
          id: string
          kind: string
          note: string | null
          order_id: string | null
          points: number
          restaurant_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          customer_id: string
          id?: string
          kind: string
          note?: string | null
          order_id?: string | null
          points: number
          restaurant_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          customer_id?: string
          id?: string
          kind?: string
          note?: string | null
          order_id?: string | null
          points?: number
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "loyalty_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loyalty_ledger_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "loyalty_ledger_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loyalty_ledger_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "loyalty_ledger_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      loyalty_settings: {
        Row: {
          min_redeem: number
          point_value: number
          restaurant_id: string
          spend_per_point: number
          updated_at: string
        }
        Insert: {
          min_redeem?: number
          point_value?: number
          restaurant_id: string
          spend_per_point?: number
          updated_at?: string
        }
        Update: {
          min_redeem?: number
          point_value?: number
          restaurant_id?: string
          spend_per_point?: number
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "loyalty_settings_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: true
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      meal_sessions: {
        Row: {
          branch_id: string | null
          created_at: string
          days: number[]
          display_order: number
          end_time: string
          id: string
          name: string
          restaurant_id: string
          start_time: string
        }
        Insert: {
          branch_id?: string | null
          created_at?: string
          days?: number[]
          display_order?: number
          end_time: string
          id?: string
          name: string
          restaurant_id: string
          start_time: string
        }
        Update: {
          branch_id?: string | null
          created_at?: string
          days?: number[]
          display_order?: number
          end_time?: string
          id?: string
          name?: string
          restaurant_id?: string
          start_time?: string
        }
        Relationships: [
          {
            foreignKeyName: "meal_sessions_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "meal_sessions_restaurant_id_fkey"
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
      modules: {
        Row: {
          description: string
          display_order: number
          key: string
          kind: string
          name: string
        }
        Insert: {
          description: string
          display_order?: number
          key: string
          kind: string
          name: string
        }
        Update: {
          description?: string
          display_order?: number
          key?: string
          kind?: string
          name?: string
        }
        Relationships: []
      }
      offline_series: {
        Row: {
          branch_id: string
          created_at: string
          device_key: string
          fy: string | null
          id: string
          last_sync_at: string | null
          next_seq: number
          prefix: string
          restaurant_id: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          device_key: string
          fy?: string | null
          id?: string
          last_sync_at?: string | null
          next_seq?: number
          prefix: string
          restaurant_id: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          device_key?: string
          fy?: string | null
          id?: string
          last_sync_at?: string | null
          next_seq?: number
          prefix?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "offline_series_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "offline_series_restaurant_id_fkey"
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
          held: boolean
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
          product_name_local: string | null
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
          held?: boolean
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
          product_name_local?: string | null
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
          held?: boolean
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
          product_name_local?: string | null
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
          client_ref: string | null
          comp_by: string | null
          comp_kind: string | null
          comp_reason: string | null
          created_at: string
          currency_code: string
          customer_id: string | null
          delivery_address: string | null
          device_id: string | null
          dining_table_id: string | null
          discount_total: number
          exempt_sales: number
          grand_total: number
          guest_name: string | null
          guest_phone: string | null
          id: string
          merged_into: string | null
          offline_flags: Json | null
          order_type: string
          paid_total: number
          payment_status: string
          place_of_supply: string | null
          receipt_token: string | null
          restaurant_id: string
          rounding_adjustment: number
          senior_details: Json | null
          service_charge: number
          session_id: string | null
          session_name: string | null
          shift_id: string | null
          status: string
          subtotal: number
          synced_at: string | null
          tax_exempt_amount: number
          tax_included: number
          tax_total: number
          token_no: number | null
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
          client_ref?: string | null
          comp_by?: string | null
          comp_kind?: string | null
          comp_reason?: string | null
          created_at?: string
          currency_code: string
          customer_id?: string | null
          delivery_address?: string | null
          device_id?: string | null
          dining_table_id?: string | null
          discount_total?: number
          exempt_sales?: number
          grand_total?: number
          guest_name?: string | null
          guest_phone?: string | null
          id: string
          merged_into?: string | null
          offline_flags?: Json | null
          order_type: string
          paid_total?: number
          payment_status?: string
          place_of_supply?: string | null
          receipt_token?: string | null
          restaurant_id: string
          rounding_adjustment?: number
          senior_details?: Json | null
          service_charge?: number
          session_id?: string | null
          session_name?: string | null
          shift_id?: string | null
          status?: string
          subtotal?: number
          synced_at?: string | null
          tax_exempt_amount?: number
          tax_included?: number
          tax_total?: number
          token_no?: number | null
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
          client_ref?: string | null
          comp_by?: string | null
          comp_kind?: string | null
          comp_reason?: string | null
          created_at?: string
          currency_code?: string
          customer_id?: string | null
          delivery_address?: string | null
          device_id?: string | null
          dining_table_id?: string | null
          discount_total?: number
          exempt_sales?: number
          grand_total?: number
          guest_name?: string | null
          guest_phone?: string | null
          id?: string
          merged_into?: string | null
          offline_flags?: Json | null
          order_type?: string
          paid_total?: number
          payment_status?: string
          place_of_supply?: string | null
          receipt_token?: string | null
          restaurant_id?: string
          rounding_adjustment?: number
          senior_details?: Json | null
          service_charge?: number
          session_id?: string | null
          session_name?: string | null
          shift_id?: string | null
          status?: string
          subtotal?: number
          synced_at?: string | null
          tax_exempt_amount?: number
          tax_included?: number
          tax_total?: number
          token_no?: number | null
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
            foreignKeyName: "orders_comp_by_fkey"
            columns: ["comp_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "orders_comp_by_fkey"
            columns: ["comp_by"]
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
      owner_alerts: {
        Row: {
          body: string
          branch_id: string | null
          created_at: string
          id: string
          kind: string
          restaurant_id: string
          title: string
        }
        Insert: {
          body: string
          branch_id?: string | null
          created_at?: string
          id?: string
          kind: string
          restaurant_id: string
          title: string
        }
        Update: {
          body?: string
          branch_id?: string | null
          created_at?: string
          id?: string
          kind?: string
          restaurant_id?: string
          title?: string
        }
        Relationships: [
          {
            foreignKeyName: "owner_alerts_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "owner_alerts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
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
          client_ref: string | null
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
          client_ref?: string | null
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
          client_ref?: string | null
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
      plan_prices: {
        Row: {
          currency_code: string
          item: string
          monthly_price: number | null
        }
        Insert: {
          currency_code: string
          item: string
          monthly_price?: number | null
        }
        Update: {
          currency_code?: string
          item?: string
          monthly_price?: number | null
        }
        Relationships: []
      }
      plan_requests: {
        Row: {
          branch_id: string | null
          created_at: string
          decided_at: string | null
          decided_by: string | null
          decision_note: string | null
          done_at: string | null
          done_by: string | null
          id: string
          kind: string
          module_key: string | null
          note: string | null
          outlet_city: string | null
          outlet_name: string | null
          requested_by_staff: string | null
          requested_by_user: string | null
          restaurant_id: string
          status: string
        }
        Insert: {
          branch_id?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_note?: string | null
          done_at?: string | null
          done_by?: string | null
          id?: string
          kind: string
          module_key?: string | null
          note?: string | null
          outlet_city?: string | null
          outlet_name?: string | null
          requested_by_staff?: string | null
          requested_by_user?: string | null
          restaurant_id: string
          status?: string
        }
        Update: {
          branch_id?: string | null
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          decision_note?: string | null
          done_at?: string | null
          done_by?: string | null
          id?: string
          kind?: string
          module_key?: string | null
          note?: string | null
          outlet_city?: string | null
          outlet_name?: string | null
          requested_by_staff?: string | null
          requested_by_user?: string | null
          restaurant_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "plan_requests_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_requests_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_requests_done_by_fkey"
            columns: ["done_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_requests_module_key_fkey"
            columns: ["module_key"]
            isOneToOne: false
            referencedRelation: "modules"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "plan_requests_requested_by_staff_fkey"
            columns: ["requested_by_staff"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_requests_requested_by_user_fkey"
            columns: ["requested_by_user"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "plan_requests_requested_by_user_fkey"
            columns: ["requested_by_user"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "plan_requests_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
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
      product_price_history: {
        Row: {
          id: number
          price: number
          product_id: string
          restaurant_id: string
          valid_from: string
          valid_to: string | null
        }
        Insert: {
          id?: number
          price: number
          product_id: string
          restaurant_id: string
          valid_from?: string
          valid_to?: string | null
        }
        Update: {
          id?: number
          price?: number
          product_id?: string
          restaurant_id?: string
          valid_from?: string
          valid_to?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "product_price_history_restaurant_id_fkey"
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
          is_charge: boolean
          is_veg: boolean | null
          kitchen_station: string | null
          name: string
          name_local: string | null
          parent_id: string | null
          price: number
          restaurant_id: string
          short_name: string | null
          sku: string | null
          tax_group_id: string
          updated_at: string
          variant_name: string | null
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
          is_charge?: boolean
          is_veg?: boolean | null
          kitchen_station?: string | null
          name: string
          name_local?: string | null
          parent_id?: string | null
          price: number
          restaurant_id: string
          short_name?: string | null
          sku?: string | null
          tax_group_id: string
          updated_at?: string
          variant_name?: string | null
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
          is_charge?: boolean
          is_veg?: boolean | null
          kitchen_station?: string | null
          name?: string
          name_local?: string | null
          parent_id?: string | null
          price?: number
          restaurant_id?: string
          short_name?: string | null
          sku?: string | null
          tax_group_id?: string
          updated_at?: string
          variant_name?: string | null
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
      purchase_order_lines: {
        Row: {
          id: string
          ingredient_id: string
          purchase_order_id: string
          qty: number
          received_qty: number
          restaurant_id: string
          unit_cost: number
        }
        Insert: {
          id?: string
          ingredient_id: string
          purchase_order_id: string
          qty: number
          received_qty?: number
          restaurant_id: string
          unit_cost?: number
        }
        Update: {
          id?: string
          ingredient_id?: string
          purchase_order_id?: string
          qty?: number
          received_qty?: number
          restaurant_id?: string
          unit_cost?: number
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_restaurant_id_ingredient_id_fkey"
            columns: ["restaurant_id", "ingredient_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "purchase_order_lines_restaurant_id_purchase_order_id_fkey"
            columns: ["restaurant_id", "purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      purchase_orders: {
        Row: {
          branch_id: string
          closed_at: string | null
          created_at: string
          created_by: string
          expected_on: string | null
          id: string
          notes: string | null
          number: string
          ordered_at: string | null
          restaurant_id: string
          status: string
          supplier_id: string
          total: number
        }
        Insert: {
          branch_id: string
          closed_at?: string | null
          created_at?: string
          created_by: string
          expected_on?: string | null
          id?: string
          notes?: string | null
          number: string
          ordered_at?: string | null
          restaurant_id: string
          status?: string
          supplier_id: string
          total?: number
        }
        Update: {
          branch_id?: string
          closed_at?: string | null
          created_at?: string
          created_by?: string
          expected_on?: string | null
          id?: string
          notes?: string | null
          number?: string
          ordered_at?: string | null
          restaurant_id?: string
          status?: string
          supplier_id?: string
          total?: number
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "purchase_orders_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "purchase_orders_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_restaurant_id_supplier_id_fkey"
            columns: ["restaurant_id", "supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      push_subscriptions: {
        Row: {
          auth: string
          created_at: string
          endpoint: string
          id: string
          p256dh: string
          restaurant_id: string
          user_id: string
        }
        Insert: {
          auth: string
          created_at?: string
          endpoint: string
          id?: string
          p256dh: string
          restaurant_id: string
          user_id: string
        }
        Update: {
          auth?: string
          created_at?: string
          endpoint?: string
          id?: string
          p256dh?: string
          restaurant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "push_subscriptions_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "push_subscriptions_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      qr_orders: {
        Row: {
          branch_id: string
          created_at: string
          decided_at: string | null
          decided_by: string | null
          dining_table_id: string
          estimated_total: number | null
          guest_key: string
          guest_name: string | null
          guest_note: string | null
          id: string
          items: Json
          order_id: string | null
          reject_reason: string | null
          restaurant_id: string
          status: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          dining_table_id: string
          estimated_total?: number | null
          guest_key: string
          guest_name?: string | null
          guest_note?: string | null
          id?: string
          items: Json
          order_id?: string | null
          reject_reason?: string | null
          restaurant_id: string
          status?: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          decided_at?: string | null
          decided_by?: string | null
          dining_table_id?: string
          estimated_total?: number | null
          guest_key?: string
          guest_name?: string | null
          guest_note?: string | null
          id?: string
          items?: Json
          order_id?: string | null
          reject_reason?: string | null
          restaurant_id?: string
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "qr_orders_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "qr_orders_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "qr_orders_decided_by_fkey"
            columns: ["decided_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "qr_orders_dining_table_id_fkey"
            columns: ["dining_table_id"]
            isOneToOne: false
            referencedRelation: "dining_tables"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "qr_orders_order_id_fkey"
            columns: ["order_id"]
            isOneToOne: false
            referencedRelation: "orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "qr_orders_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      recipe_lines: {
        Row: {
          ingredient_id: string
          product_id: string
          qty: number
          restaurant_id: string
        }
        Insert: {
          ingredient_id: string
          product_id: string
          qty: number
          restaurant_id: string
        }
        Update: {
          ingredient_id?: string
          product_id?: string
          qty?: number
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "recipe_lines_restaurant_id_ingredient_id_fkey"
            columns: ["restaurant_id", "ingredient_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "recipe_lines_restaurant_id_product_id_fkey"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "products"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "recipe_lines_restaurant_id_product_id_fkey"
            columns: ["restaurant_id", "product_id"]
            isOneToOne: false
            referencedRelation: "v_menu"
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
      report_schedules: {
        Row: {
          branch_id: string
          created_at: string
          created_by: string | null
          days: number[]
          emails: string[]
          id: string
          is_active: boolean
          last_email_result: string | null
          last_for_date: string | null
          last_problem: string | null
          last_problem_at: string | null
          last_result: string | null
          last_run_on: string | null
          last_sent_at: string | null
          phone_alert: boolean
          restaurant_id: string
          send_time: string
          updated_at: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          created_by?: string | null
          days?: number[]
          emails?: string[]
          id?: string
          is_active?: boolean
          last_email_result?: string | null
          last_for_date?: string | null
          last_problem?: string | null
          last_problem_at?: string | null
          last_result?: string | null
          last_run_on?: string | null
          last_sent_at?: string | null
          phone_alert?: boolean
          restaurant_id: string
          send_time: string
          updated_at?: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          created_by?: string | null
          days?: number[]
          emails?: string[]
          id?: string
          is_active?: boolean
          last_email_result?: string | null
          last_for_date?: string | null
          last_problem?: string | null
          last_problem_at?: string | null
          last_result?: string | null
          last_run_on?: string | null
          last_sent_at?: string | null
          phone_alert?: boolean
          restaurant_id?: string
          send_time?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "report_schedules_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "report_schedules_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "report_schedules_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "report_schedules_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      report_send_days: {
        Row: {
          day: string
          emails: number
          scope: string
          sends: number
          tests: number
        }
        Insert: {
          day: string
          emails?: number
          scope: string
          sends?: number
          tests?: number
        }
        Update: {
          day?: string
          emails?: number
          scope?: string
          sends?: number
          tests?: number
        }
        Relationships: []
      }
      request_refs: {
        Row: {
          created_at: string
          kind: string
          order_id: string | null
          ref: string
          restaurant_id: string
          result: Json
        }
        Insert: {
          created_at?: string
          kind: string
          order_id?: string | null
          ref: string
          restaurant_id: string
          result: Json
        }
        Update: {
          created_at?: string
          kind?: string
          order_id?: string | null
          ref?: string
          restaurant_id?: string
          result?: Json
        }
        Relationships: [
          {
            foreignKeyName: "request_refs_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      reservations: {
        Row: {
          branch_id: string
          created_at: string
          created_by: string | null
          dining_table_id: string | null
          guest_name: string
          id: string
          note: string | null
          party_size: number
          phone: string | null
          reserved_for: string | null
          restaurant_id: string
          seated_at: string | null
          status: string
          updated_at: string
        }
        Insert: {
          branch_id: string
          created_at?: string
          created_by?: string | null
          dining_table_id?: string | null
          guest_name: string
          id?: string
          note?: string | null
          party_size: number
          phone?: string | null
          reserved_for?: string | null
          restaurant_id: string
          seated_at?: string | null
          status: string
          updated_at?: string
        }
        Update: {
          branch_id?: string
          created_at?: string
          created_by?: string | null
          dining_table_id?: string | null
          guest_name?: string
          id?: string
          note?: string | null
          party_size?: number
          phone?: string | null
          reserved_for?: string | null
          restaurant_id?: string
          seated_at?: string | null
          status?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "reservations_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "reservations_dining_table_id_fkey"
            columns: ["dining_table_id"]
            isOneToOne: false
            referencedRelation: "dining_tables"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "reservations_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      restaurant_modules: {
        Row: {
          enabled_at: string
          enabled_by: string | null
          module_key: string
          restaurant_id: string
        }
        Insert: {
          enabled_at?: string
          enabled_by?: string | null
          module_key: string
          restaurant_id: string
        }
        Update: {
          enabled_at?: string
          enabled_by?: string | null
          module_key?: string
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "restaurant_modules_module_key_fkey"
            columns: ["module_key"]
            isOneToOne: false
            referencedRelation: "modules"
            referencedColumns: ["key"]
          },
          {
            foreignKeyName: "restaurant_modules_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      restaurants: {
        Row: {
          backup_phone: string | null
          client_code: string
          contact_email: string | null
          contact_phone: string | null
          country_code: string
          created_at: string
          currency_code: string
          deleted_at: string | null
          edition: string
          fssai_no: string | null
          id: string
          legal_name: string
          logo_url: string | null
          sac_code: string | null
          second_language: string | null
          subscription_status: string
          tax_registration_no: string | null
          timezone: string
          trading_name: string
          updated_at: string
        }
        Insert: {
          backup_phone?: string | null
          client_code?: string
          contact_email?: string | null
          contact_phone?: string | null
          country_code: string
          created_at?: string
          currency_code: string
          deleted_at?: string | null
          edition?: string
          fssai_no?: string | null
          id?: string
          legal_name: string
          logo_url?: string | null
          sac_code?: string | null
          second_language?: string | null
          subscription_status?: string
          tax_registration_no?: string | null
          timezone: string
          trading_name: string
          updated_at?: string
        }
        Update: {
          backup_phone?: string | null
          client_code?: string
          contact_email?: string | null
          contact_phone?: string | null
          country_code?: string
          created_at?: string
          currency_code?: string
          deleted_at?: string | null
          edition?: string
          fssai_no?: string | null
          id?: string
          legal_name?: string
          logo_url?: string | null
          sac_code?: string | null
          second_language?: string | null
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
      shift_closings: {
        Row: {
          created_at: string
          figures: Json
          restaurant_id: string
          shift_id: string
          unpaid_orders: string[]
        }
        Insert: {
          created_at?: string
          figures: Json
          restaurant_id: string
          shift_id: string
          unpaid_orders?: string[]
        }
        Update: {
          created_at?: string
          figures?: Json
          restaurant_id?: string
          shift_id?: string
          unpaid_orders?: string[]
        }
        Relationships: [
          {
            foreignKeyName: "shift_closings_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shift_closings_shift_id_fkey"
            columns: ["shift_id"]
            isOneToOne: true
            referencedRelation: "shifts"
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
      sna_accounts: {
        Row: {
          account_manager: string | null
          last_contact: string | null
          licence_expiry: string | null
          licence_start: string | null
          live_at: string | null
          live_by: string | null
          next_contact: string | null
          reminder_off_for: string | null
          restaurant_id: string
          sales_person: string | null
          support_person: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          account_manager?: string | null
          last_contact?: string | null
          licence_expiry?: string | null
          licence_start?: string | null
          live_at?: string | null
          live_by?: string | null
          next_contact?: string | null
          reminder_off_for?: string | null
          restaurant_id: string
          sales_person?: string | null
          support_person?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          account_manager?: string | null
          last_contact?: string | null
          licence_expiry?: string | null
          licence_start?: string | null
          live_at?: string | null
          live_by?: string | null
          next_contact?: string | null
          reminder_off_for?: string | null
          restaurant_id?: string
          sales_person?: string | null
          support_person?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sna_accounts_account_manager_fkey"
            columns: ["account_manager"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_accounts_live_by_fkey"
            columns: ["live_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_accounts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: true
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_accounts_sales_person_fkey"
            columns: ["sales_person"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_accounts_support_person_fkey"
            columns: ["support_person"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_accounts_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
        ]
      }
      sna_contacts: {
        Row: {
          created_at: string
          created_by: string | null
          email: string | null
          full_name: string
          id: string
          job_title: string | null
          kind: string
          phone: string | null
          removed_at: string | null
          restaurant_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          email?: string | null
          full_name: string
          id?: string
          job_title?: string | null
          kind?: string
          phone?: string | null
          removed_at?: string | null
          restaurant_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          email?: string | null
          full_name?: string
          id?: string
          job_title?: string | null
          kind?: string
          phone?: string | null
          removed_at?: string | null
          restaurant_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sna_contacts_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_contacts_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
        ]
      }
      sna_notes: {
        Row: {
          body: string
          created_at: string
          id: string
          kind: string
          restaurant_id: string
          staff_id: string | null
        }
        Insert: {
          body: string
          created_at?: string
          id?: string
          kind?: string
          restaurant_id: string
          staff_id?: string | null
        }
        Update: {
          body?: string
          created_at?: string
          id?: string
          kind?: string
          restaurant_id?: string
          staff_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sna_notes_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_notes_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
        ]
      }
      sna_sales: {
        Row: {
          amount: number
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          created_at: string
          currency_code: string
          description: string
          id: string
          invoice_no: string | null
          kind: string
          modules: string[]
          note: string | null
          paid_on: string | null
          period_from: string | null
          period_to: string | null
          restaurant_id: string
          sale_date: string
          staff_id: string | null
        }
        Insert: {
          amount: number
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          created_at?: string
          currency_code: string
          description: string
          id?: string
          invoice_no?: string | null
          kind: string
          modules?: string[]
          note?: string | null
          paid_on?: string | null
          period_from?: string | null
          period_to?: string | null
          restaurant_id: string
          sale_date: string
          staff_id?: string | null
        }
        Update: {
          amount?: number
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          created_at?: string
          currency_code?: string
          description?: string
          id?: string
          invoice_no?: string | null
          kind?: string
          modules?: string[]
          note?: string | null
          paid_on?: string | null
          period_from?: string | null
          period_to?: string | null
          restaurant_id?: string
          sale_date?: string
          staff_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sna_sales_cancelled_by_fkey"
            columns: ["cancelled_by"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_sales_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sna_sales_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
        ]
      }
      sna_staff: {
        Row: {
          auth_user_id: string
          created_at: string
          email: string
          full_name: string
          id: string
          is_active: boolean
          role: string
        }
        Insert: {
          auth_user_id: string
          created_at?: string
          email: string
          full_name: string
          id?: string
          is_active?: boolean
          role: string
        }
        Update: {
          auth_user_id?: string
          created_at?: string
          email?: string
          full_name?: string
          id?: string
          is_active?: boolean
          role?: string
        }
        Relationships: []
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
      stock_movements: {
        Row: {
          branch_id: string
          created_at: string
          created_by: string | null
          goods_receipt_id: string | null
          id: string
          ingredient_id: string
          kind: string
          note: string | null
          order_id: string | null
          order_item_id: string | null
          qty: number
          restaurant_id: string
          transfer_id: string | null
          unit_cost: number | null
        }
        Insert: {
          branch_id: string
          created_at?: string
          created_by?: string | null
          goods_receipt_id?: string | null
          id?: string
          ingredient_id: string
          kind: string
          note?: string | null
          order_id?: string | null
          order_item_id?: string | null
          qty: number
          restaurant_id: string
          transfer_id?: string | null
          unit_cost?: number | null
        }
        Update: {
          branch_id?: string
          created_at?: string
          created_by?: string | null
          goods_receipt_id?: string | null
          id?: string
          ingredient_id?: string
          kind?: string
          note?: string | null
          order_id?: string | null
          order_item_id?: string | null
          qty?: number
          restaurant_id?: string
          transfer_id?: string | null
          unit_cost?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "stock_movements_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "stock_movements_restaurant_id_ingredient_id_fkey"
            columns: ["restaurant_id", "ingredient_id"]
            isOneToOne: false
            referencedRelation: "ingredients"
            referencedColumns: ["restaurant_id", "id"]
          },
        ]
      }
      subscription_events: {
        Row: {
          created_at: string
          details: Json
          event: string
          id: string
          restaurant_id: string | null
          staff_id: string | null
          user_id: string | null
        }
        Insert: {
          created_at?: string
          details?: Json
          event: string
          id?: string
          restaurant_id?: string | null
          staff_id?: string | null
          user_id?: string | null
        }
        Update: {
          created_at?: string
          details?: Json
          event?: string
          id?: string
          restaurant_id?: string | null
          staff_id?: string | null
          user_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "subscription_events_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscription_events_staff_id_fkey"
            columns: ["staff_id"]
            isOneToOne: false
            referencedRelation: "sna_staff"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscription_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "subscription_events_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
        ]
      }
      supplier_payments: {
        Row: {
          amount: number
          branch_id: string
          cash_movement_id: string | null
          client_ref: string | null
          created_at: string
          from_till: boolean
          goods_receipt_id: string
          id: string
          method: string
          paid_by: string
          paid_on: string
          reason: string | null
          reference: string | null
          restaurant_id: string
          reverses_id: string | null
          supplier_id: string
        }
        Insert: {
          amount: number
          branch_id: string
          cash_movement_id?: string | null
          client_ref?: string | null
          created_at?: string
          from_till?: boolean
          goods_receipt_id: string
          id?: string
          method: string
          paid_by: string
          paid_on: string
          reason?: string | null
          reference?: string | null
          restaurant_id: string
          reverses_id?: string | null
          supplier_id: string
        }
        Update: {
          amount?: number
          branch_id?: string
          cash_movement_id?: string | null
          client_ref?: string | null
          created_at?: string
          from_till?: boolean
          goods_receipt_id?: string
          id?: string
          method?: string
          paid_by?: string
          paid_on?: string
          reason?: string | null
          reference?: string | null
          restaurant_id?: string
          reverses_id?: string | null
          supplier_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "supplier_payments_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_payments_paid_by_fkey"
            columns: ["paid_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "supplier_payments_restaurant_id_branch_id_fkey"
            columns: ["restaurant_id", "branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "supplier_payments_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_payments_restaurant_id_goods_receipt_id_fkey"
            columns: ["restaurant_id", "goods_receipt_id"]
            isOneToOne: false
            referencedRelation: "goods_receipts"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "supplier_payments_restaurant_id_supplier_id_fkey"
            columns: ["restaurant_id", "supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["restaurant_id", "id"]
          },
          {
            foreignKeyName: "supplier_payments_reverses_id_fkey"
            columns: ["reverses_id"]
            isOneToOne: false
            referencedRelation: "supplier_payments"
            referencedColumns: ["id"]
          },
        ]
      }
      suppliers: {
        Row: {
          address: string | null
          contact_person: string | null
          created_at: string
          email: string | null
          id: string
          is_active: boolean
          name: string
          notes: string | null
          payment_days: number
          phone: string | null
          restaurant_id: string
          tax_no: string | null
        }
        Insert: {
          address?: string | null
          contact_person?: string | null
          created_at?: string
          email?: string | null
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          payment_days?: number
          phone?: string | null
          restaurant_id: string
          tax_no?: string | null
        }
        Update: {
          address?: string | null
          contact_person?: string | null
          created_at?: string
          email?: string | null
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          payment_days?: number
          phone?: string | null
          restaurant_id?: string
          tax_no?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "suppliers_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
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
      time_entries: {
        Row: {
          branch_id: string
          clock_in: string
          clock_out: string | null
          created_at: string
          edit_reason: string | null
          edited_by: string | null
          id: string
          restaurant_id: string
          user_id: string
        }
        Insert: {
          branch_id: string
          clock_in: string
          clock_out?: string | null
          created_at?: string
          edit_reason?: string | null
          edited_by?: string | null
          id?: string
          restaurant_id: string
          user_id: string
        }
        Update: {
          branch_id?: string
          clock_in?: string
          clock_out?: string | null
          created_at?: string
          edit_reason?: string | null
          edited_by?: string | null
          id?: string
          restaurant_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "time_entries_branch_id_fkey"
            columns: ["branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_entries_edited_by_fkey"
            columns: ["edited_by"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_entries_edited_by_fkey"
            columns: ["edited_by"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "time_entries_restaurant_id_fkey"
            columns: ["restaurant_id"]
            isOneToOne: false
            referencedRelation: "restaurants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_entries_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "users"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "time_entries_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "v_current_user"
            referencedColumns: ["user_id"]
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
          all_outlets: boolean
          auth_user_id: string | null
          created_at: string
          current_branch_id: string | null
          deleted_at: string | null
          email: string | null
          employee_code: string
          full_name: string
          id: string
          is_active: boolean
          last_login_at: string | null
          login_failed_count: number
          login_locked_until: string | null
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
          all_outlets?: boolean
          auth_user_id?: string | null
          created_at?: string
          current_branch_id?: string | null
          deleted_at?: string | null
          email?: string | null
          employee_code: string
          full_name: string
          id?: string
          is_active?: boolean
          last_login_at?: string | null
          login_failed_count?: number
          login_locked_until?: string | null
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
          all_outlets?: boolean
          auth_user_id?: string | null
          created_at?: string
          current_branch_id?: string | null
          deleted_at?: string | null
          email?: string | null
          employee_code?: string
          full_name?: string
          id?: string
          is_active?: boolean
          last_login_at?: string | null
          login_failed_count?: number
          login_locked_until?: string | null
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
            foreignKeyName: "users_current_branch_id_fkey"
            columns: ["current_branch_id"]
            isOneToOne: false
            referencedRelation: "branches"
            referencedColumns: ["id"]
          },
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
          branch_id: string | null
          branch_name: string | null
          country_code: string | null
          currency_code: string | null
          device_name: string | null
          edition: string | null
          email: string | null
          employee_code: string | null
          features: string[] | null
          full_name: string | null
          is_sna_staff: boolean | null
          must_change_password: boolean | null
          outlet_count: number | null
          permissions: string[] | null
          restaurant_id: string | null
          role_id: string | null
          role_name: string | null
          second_language: string | null
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
          menu_price: number | null
          name: string | null
          name_local: string | null
          parent_id: string | null
          price: number | null
          restaurant_id: string | null
          short_name: string | null
          tax_group_id: string | null
          tax_group_name: string | null
          tax_rate: number | null
          variant_name: string | null
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
      accept_qr_order: { Args: { p_id: string }; Returns: Json }
      account_date: { Args: never; Returns: Json }
      accounting_journal: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      add_order_items: {
        Args: { p_client_ref?: string; p_items: Json; p_order_id: string }
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
      api_v1: {
        Args: { p_action: string; p_key: string; p_params?: Json }
        Returns: Json
      }
      approve_with_pin: {
        Args: { p_permission: string; p_pin: string }
        Returns: Json
      }
      attach_customer: {
        Args: { p_name?: string; p_order: string; p_phone: string }
        Returns: Json
      }
      bill_prefix_info: { Args: never; Returns: Json }
      cancel_goods_receipt: {
        Args: { p_id: string; p_reason: string }
        Returns: Json
      }
      cancel_invite: { Args: { p_user_id: string }; Returns: undefined }
      cancel_order_item: {
        Args: { p_order_item_id: string; p_qty: number; p_reason: string }
        Returns: Json
      }
      cancel_plan_request: { Args: { p_id: string }; Returns: undefined }
      change_payment_method: {
        Args: { p_method_id: string; p_payment_id: string; p_reason: string }
        Returns: Json
      }
      claim_staff_invite: { Args: { p_code: string }; Returns: string }
      claim_tickets_for_print: { Args: { p_ids: string[] }; Returns: string[] }
      clear_pin_lockout: { Args: { p_device_id: string }; Returns: undefined }
      clear_staff_pin: { Args: { p_user_id: string }; Returns: undefined }
      clock_in: { Args: never; Returns: Json }
      clock_out: { Args: never; Returns: Json }
      close_day: {
        Args: { p_counted_cash?: number; p_notes?: string }
        Returns: Json
      }
      close_shift: {
        Args: { p_counted_cash: number; p_notes?: string }
        Returns: Json
      }
      create_api_key: { Args: { p_name: string }; Returns: Json }
      create_order: {
        Args: {
          p_client_ref?: string
          p_customer_id?: string
          p_discount_amount?: number
          p_discount_reason?: string
          p_extra?: Json
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
      fire_held_items: { Args: { p_order_id: string }; Returns: Json }
      fix_time_entry: {
        Args: { p_id: string; p_in: string; p_out: string; p_reason: string }
        Returns: undefined
      }
      gift_card_lookup: { Args: { p_code: string }; Returns: Json }
      gst_register: { Args: { p_from: string; p_to: string }; Returns: Json }
      import_menu: { Args: { p_apply?: boolean; p_rows: Json }; Returns: Json }
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
          p_client_ref?: string
          p_method_id: string
          p_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      issue_gift_card: {
        Args: {
          p_method_id: string
          p_name?: string
          p_phone?: string
          p_valid_days?: number
          p_value: number
        }
        Returns: Json
      }
      login_staff: {
        Args: { p_client_code: string; p_password: string; p_username: string }
        Returns: Json
      }
      make_complimentary: {
        Args: { p_kind: string; p_order_id: string; p_reason: string }
        Returns: Json
      }
      mark_tickets_printed: { Args: { p_ids: string[] }; Returns: number }
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
      my_licence: { Args: never; Returns: Json }
      my_outlets: { Args: never; Returns: Json }
      my_plan: { Args: never; Returns: Json }
      offline_snapshot: { Args: { p_device_key: string }; Returns: Json }
      open_shift: { Args: { p_opening_float?: number }; Returns: string }
      outlet_comparison: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      password_changed: { Args: never; Returns: undefined }
      pay_order: {
        Args: {
          p_amount?: number
          p_client_ref?: string
          p_order_id: string
          p_payment_method_id: string
          p_reference?: string
          p_tendered?: number
        }
        Returns: Json
      }
      pay_supplier: {
        Args: {
          p_amount: number
          p_client_ref?: string
          p_from_till?: boolean
          p_method: string
          p_paid_on?: string
          p_receipt_id: string
          p_reference?: string
        }
        Returns: Json
      }
      pin_lock: { Args: never; Returns: undefined }
      pin_touch: { Args: never; Returns: boolean }
      pin_unlock: { Args: { p_pin: string }; Returns: Json }
      public_receipt: { Args: { p_token: string }; Returns: Json }
      purchase_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      push_gone: {
        Args: { p_endpoints: string[]; p_secret: string }
        Returns: undefined
      }
      qr_menu: { Args: { p_token: string }; Returns: Json }
      qr_order_status: {
        Args: { p_key: string; p_request: string }
        Returns: Json
      }
      qr_place_order: {
        Args: {
          p_guest_name?: string
          p_items: Json
          p_note?: string
          p_token: string
        }
        Returns: Json
      }
      quote_order: {
        Args: {
          p_discount_amount?: number
          p_items: Json
          p_senior?: Json
          p_service_charge?: boolean
        }
        Returns: Json
      }
      receive_goods: {
        Args: {
          p_bill_date?: string
          p_bill_no?: string
          p_client_ref?: string
          p_due_on?: string
          p_lines: Json
          p_notes?: string
          p_other?: number
          p_payment?: Json
          p_purchase_order_id?: string
          p_supplier_id: string
          p_tax?: number
        }
        Returns: Json
      }
      record_cash_movement: {
        Args: { p_amount: number; p_direction: string; p_reason: string }
        Returns: string
      }
      record_stock: {
        Args: {
          p_ingredient_id: string
          p_kind: string
          p_note?: string
          p_qty: number
          p_unit_cost?: number
        }
        Returns: Json
      }
      redeem_gift_card: {
        Args: { p_amount?: number; p_code: string; p_order: string }
        Returns: Json
      }
      redeem_points: {
        Args: { p_order: string; p_points: number }
        Returns: Json
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
      reject_qr_order: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      remove_counter_device: {
        Args: { p_device_id: string }
        Returns: undefined
      }
      remove_push_subscription: {
        Args: { p_endpoint: string }
        Returns: undefined
      }
      remove_report_schedule: { Args: { p_id: string }; Returns: undefined }
      reopen_day: { Args: { p_reason: string }; Returns: Json }
      report_schedules_list: { Args: never; Returns: Json }
      report_sent: {
        Args: {
          p_note: string
          p_ok: boolean
          p_schedule: string
          p_secret: string
        }
        Returns: undefined
      }
      request_plan_change: {
        Args: {
          p_kind: string
          p_module?: string
          p_note?: string
          p_outlet_city?: string
          p_outlet_name?: string
        }
        Returns: string
      }
      reset_table_qr: { Args: { p_table: string }; Returns: undefined }
      revoke_api_key: { Args: { p_id: string }; Returns: undefined }
      sales_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      save_day_settings: {
        Args: { p_cutoff: string; p_shifts_enabled: boolean }
        Returns: undefined
      }
      save_ingredient: {
        Args: {
          p_category?: string
          p_cost: number
          p_id: string
          p_name: string
          p_reorder: number
          p_unit: string
        }
        Returns: string
      }
      save_loyalty_settings: {
        Args: {
          p_min_redeem: number
          p_point_value: number
          p_spend_per_point: number
        }
        Returns: undefined
      }
      save_meal_sessions: {
        Args: { p_branch: string; p_sessions: Json }
        Returns: undefined
      }
      save_packing_charge: {
        Args: {
          p_amount: number
          p_delivery?: boolean
          p_per: string
          p_takeaway?: boolean
          p_tax_group_id: string
        }
        Returns: Json
      }
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
      save_purchase_order: {
        Args: {
          p_expected_on?: string
          p_id: string
          p_lines: Json
          p_notes?: string
          p_place?: boolean
          p_supplier_id: string
        }
        Returns: Json
      }
      save_push_subscription: {
        Args: { p_auth: string; p_endpoint: string; p_p256dh: string }
        Returns: undefined
      }
      save_recipe: {
        Args: { p_lines: Json; p_product_id: string }
        Returns: number
      }
      save_report_schedule: { Args: { p: Json; p_id: string }; Returns: Json }
      save_reservation: {
        Args: {
          p_id: string
          p_name: string
          p_note: string
          p_party: number
          p_phone: string
          p_table: string
          p_when: string
        }
        Returns: string
      }
      save_role: {
        Args: { p_name: string; p_permissions: string[]; p_role_id: string }
        Returns: string
      }
      save_supplier: { Args: { p: Json; p_id: string }; Returns: string }
      save_tax_group: {
        Args: { p_components: Json; p_group_id: string; p_name: string }
        Returns: string
      }
      send_report_now: { Args: { p_id: string }; Returns: Json }
      send_to_kitchen: { Args: { p_order: string }; Returns: Json }
      session_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      set_bill_customer: {
        Args: { p_gstin: string; p_name: string; p_order_id: string }
        Returns: Json
      }
      set_bill_prefix: { Args: { p_prefix: string }; Returns: Json }
      set_central_kitchen: {
        Args: { p_branch: string; p_on: boolean }
        Returns: undefined
      }
      set_current_outlet: {
        Args: { p_all?: boolean; p_branch: string }
        Returns: undefined
      }
      set_kitchen_status: {
        Args: { p_status: string; p_ticket_id: string }
        Returns: undefined
      }
      set_order_guest: {
        Args: {
          p_address?: string
          p_name: string
          p_order_id: string
          p_phone: string
        }
        Returns: Json
      }
      set_outlet_price: {
        Args: {
          p_available: boolean
          p_branch_id: string
          p_price: number
          p_product_id: string
        }
        Returns: undefined
      }
      set_prices_include_tax: {
        Args: { p_inclusive: boolean }
        Returns: undefined
      }
      set_purchase_order_status: {
        Args: { p_action: string; p_id: string }
        Returns: Json
      }
      set_report_schedule_active: {
        Args: { p_id: string; p_on: boolean }
        Returns: undefined
      }
      set_reservation_status: {
        Args: { p_id: string; p_status: string; p_table?: string }
        Returns: undefined
      }
      set_second_language: { Args: { p_lang: string }; Returns: undefined }
      set_staff_pin: {
        Args: { p_pin?: string; p_user_id: string }
        Returns: Json
      }
      set_tax_rate: {
        Args: { p_tax_group_id: string; p_total_rate: number }
        Returns: undefined
      }
      set_user_outlets: {
        Args: { p_branches: string[]; p_user_id: string }
        Returns: undefined
      }
      settlement_report: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      share_bill: { Args: { p_order: string }; Returns: Json }
      shift_report: { Args: { p_shift_id: string }; Returns: Json }
      sna_add_note: {
        Args: {
          p_body: string
          p_kind: string
          p_next_contact?: string
          p_restaurant: string
        }
        Returns: string
      }
      sna_add_request: {
        Args: {
          p_kind: string
          p_module?: string
          p_note?: string
          p_outlet_city?: string
          p_outlet_name?: string
          p_restaurant: string
        }
        Returns: string
      }
      sna_add_sale: {
        Args: {
          p_amount: number
          p_description: string
          p_extend_licence?: boolean
          p_invoice_no?: string
          p_kind: string
          p_note?: string
          p_paid_on?: string
          p_period_from?: string
          p_period_to?: string
          p_restaurant: string
          p_sale_date: string
        }
        Returns: string
      }
      sna_cancel_sale: {
        Args: { p_id: string; p_reason: string }
        Returns: undefined
      }
      sna_client: { Args: { p_id: string }; Returns: Json }
      sna_clients: {
        Args: { p_filter?: string; p_search?: string }
        Returns: Json
      }
      sna_create_client: {
        Args: {
          p_branch_code?: string
          p_branch_name?: string
          p_country_code: string
          p_edition?: string
          p_legal_name: string
          p_licence_expiry?: string
          p_licence_start?: string
          p_owner_email: string
          p_owner_name: string
          p_tax_registration_no?: string
          p_temp_password: string
          p_trading_name: string
        }
        Returns: Json
      }
      sna_create_outlet: {
        Args: {
          p_address?: string
          p_city: string
          p_code: string
          p_name: string
          p_phone?: string
          p_request: string
          p_timezone?: string
        }
        Returns: string
      }
      sna_decide_request: {
        Args: { p_approve: boolean; p_id: string; p_note?: string }
        Returns: undefined
      }
      sna_erase: {
        Args: {
          p_client_code: string
          p_pos_master: boolean
          p_pos_tx: boolean
          p_reason: string
          p_restaurant: string
          p_stock_master: boolean
          p_stock_tx: boolean
        }
        Returns: Json
      }
      sna_erase_preview: { Args: { p_id: string }; Returns: Json }
      sna_licence: { Args: { p_id: string }; Returns: Json }
      sna_me: { Args: never; Returns: Json }
      sna_record_sale: {
        Args: {
          p_amount: number
          p_description: string
          p_extend_licence?: boolean
          p_invoice_no?: string
          p_kind: string
          p_modules?: string[]
          p_note?: string
          p_paid_on?: string
          p_period_from?: string
          p_period_to?: string
          p_restaurant: string
          p_sale_date: string
          p_switch_on?: boolean
        }
        Returns: string
      }
      sna_remove_contact: { Args: { p_id: string }; Returns: undefined }
      sna_requests: { Args: { p_status?: string }; Returns: Json }
      sna_restaurant: { Args: { p_id: string }; Returns: Json }
      sna_restaurants: { Args: { p_search?: string }; Returns: Json }
      sna_sales_list: { Args: { p_id: string }; Returns: Json }
      sna_save_account: {
        Args: {
          p_account_manager?: string
          p_licence_expiry: string
          p_licence_start: string
          p_restaurant: string
          p_sales_person?: string
          p_status: string
          p_support_person?: string
        }
        Returns: undefined
      }
      sna_save_contact: {
        Args: {
          p_email?: string
          p_full_name: string
          p_id: string
          p_job_title?: string
          p_kind: string
          p_phone?: string
          p_restaurant: string
        }
        Returns: string
      }
      sna_save_staff: {
        Args: {
          p_active?: boolean
          p_email: string
          p_full_name: string
          p_role: string
        }
        Returns: string
      }
      sna_set_edition: {
        Args: { p_edition: string; p_note?: string; p_restaurant: string }
        Returns: undefined
      }
      sna_set_follow_up: {
        Args: { p_next_contact: string; p_restaurant: string }
        Returns: undefined
      }
      sna_set_live: {
        Args: { p_live: boolean; p_reason?: string; p_restaurant: string }
        Returns: undefined
      }
      sna_set_module: {
        Args: {
          p_module: string
          p_note?: string
          p_on: boolean
          p_restaurant: string
        }
        Returns: undefined
      }
      sna_set_price: {
        Args: { p_currency: string; p_item: string; p_price: number }
        Returns: undefined
      }
      sna_set_reminder: {
        Args: { p_on: boolean; p_restaurant: string }
        Returns: undefined
      }
      sna_set_sale_paid: {
        Args: { p_id: string; p_paid_on: string }
        Returns: undefined
      }
      sna_staff_list: { Args: never; Returns: Json }
      split_order: {
        Args: { p_client_ref?: string; p_items: Json; p_order_id: string }
        Returns: Json
      }
      stock_report: { Args: { p_from: string; p_to: string }; Returns: Json }
      sync_offline_bill: { Args: { p_bill: Json }; Returns: Json }
      table_qr_codes: { Args: never; Returns: Json }
      transfer_stock: {
        Args: {
          p_ingredient_id: string
          p_note?: string
          p_qty: number
          p_to_branch: string
        }
        Returns: string
      }
      undo_supplier_payment: {
        Args: { p_payment_id: string; p_reason: string }
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
